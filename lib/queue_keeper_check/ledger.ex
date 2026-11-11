defmodule QueueKeeperCheck.Ledger do
  @moduledoc """
  Opt-in last-seen ledger for `:dead_workers`.

  Oban (and Oban Pro, unless a rule sets `archive: true`) **deletes** finished
  jobs. There is no leftover row to query after a prune, so a check that only
  reads `oban_jobs` cannot see a 14-day window when `max_age` is 60 seconds.
  This ledger is the workaround that does **not** ask you to keep more jobs:

  1. Run `QueueKeeperCheck.Ledger.Migration` in the host app (a tiny pair of
     tables, one row per worker).
  2. Attach the handler in the running application (every node that inserts
     jobs):

          {QueueKeeperCheck.Ledger, repo: MyApp.Repo, prefix: "public", backfill: true}

     or `QueueKeeperCheck.Ledger.attach(repo: MyApp.Repo, backfill: true)`.

  The handler listens for `[:oban, :engine, :insert_job, :stop]` and
  `[:oban, :engine, :insert_all_jobs, :stop]`, coalesces sightings in ETS, and
  flushes one upsert per worker every few seconds. Upserts use `GREATEST` (or
  the engine equivalent) so multiple nodes cannot move `last_inserted_at`
  backwards. Failures are logged and swallowed: a ledger error must never break
  job insertion.

  `QueueKeeperCheck.run/2` stays read-only. It **selects** from the ledger when
  the tables exist and recording has started; otherwise it falls back to
  scanning `oban_jobs`. The writer is only this process, and only after you
  opt in.

  The check stays silent (or emits `report_short_history`) until the ledger
  itself has been recording for `window_days`, so a fresh attach cannot call
  every never-yet-seen worker dead.
  """

  use GenServer
  require Logger

  @default_flush_ms 5_000
  @max_pending 20_000
  @upsert_chunk 200
  @sightings "queue_keeper_worker_sightings"
  @meta "queue_keeper_ledger_meta"

  @events [
    [:oban, :engine, :insert_job, :stop],
    [:oban, :engine, :insert_all_jobs, :stop]
  ]

  defstruct [
    :repo,
    :prefix,
    :oban_name,
    :ets,
    :handler_id,
    :flush_ms,
    :max_pending
  ]

  @doc """
  Child specification for the host application's supervisor.

  Options: `:repo` (required), `:prefix`, `:oban_name` (`:all` or an Oban
  instance name, default `:all`), `:flush_interval` (ms, default 5_000),
  `:backfill` (default `false`; one sequential scan of `oban_jobs` on start),
  `:name` (process name, default `QueueKeeperCheck.Ledger`), `:max_pending`
  (ETS cap, default 20_000).
  """
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc "Start the ledger process and attach telemetry. See `child_spec/1`."
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Start under a transient task helper; same as `start_link/1`."
  def attach(opts) when is_list(opts), do: start_link(opts)

  @doc "Detach telemetry and stop the process. Pending ETS rows are flushed first."
  def detach(server \\ __MODULE__) do
    if pid = process(server) do
      _ = flush(server)
      GenServer.stop(pid, :normal)
    else
      :ok
    end
  end

  @doc "Flush pending ETS sightings now. Returns `:ok` or `{:error, reason}`."
  def flush(server \\ __MODULE__) do
    case process(server) do
      pid when is_pid(pid) -> GenServer.call(pid, :flush, 30_000)
      nil -> {:error, :not_started}
    end
  end

  @doc """
  One-time backfill of current `oban_jobs` into the ledger (a sequential scan).
  Opt-in; also passed as `backfill: true` on `attach/1`. Safe to run more than
  once: upserts keep the later `last_inserted_at`.
  """
  def backfill(repo, opts \\ []) do
    prefix = storage_prefix(repo, opts)
    qopts = prefix_query_opts(repo, opts)
    adapter = repo.__adapter__()

    sql = """
    SELECT worker, MAX(inserted_at), MAX(id)
    FROM #{quote_table(adapter, qopts, "oban_jobs")}
    GROUP BY worker
    """

    %{rows: rows} = repo.query!(sql, [], query_opts())
    now = DateTime.utc_now()
    ensure_started(repo, prefix, now, qopts)
    upsert_rows(repo, prefix, Enum.map(rows, &row_from_agg/1), qopts)
    :ok
  end

  @doc """
  Read the ledger for a prefix, or `:absent` when the tables do not exist or
  recording has never started. Used by `:dead_workers`. Never writes.
  """
  def fetch(repo, opts \\ []) do
    prefix = storage_prefix(repo, opts)
    qopts = prefix_query_opts(repo, opts)
    adapter = repo.__adapter__()

    case ledger_tables_status(repo, adapter, qopts) do
      :absent ->
        :absent

      :present ->
        case fetch_started_at(repo, prefix, adapter, qopts) do
          {:ok, started_at} ->
            sightings = fetch_sightings(repo, prefix, adapter, qopts)
            {:ok, %{started_at: started_at, sightings: sightings, prefix: prefix}}

          :absent ->
            :absent
        end
    end
  end

  @doc false
  def handle_event(_event, _measurements, meta, server) do
    case process(server) do
      pid when is_pid(pid) -> GenServer.cast(pid, {:event, meta})
      nil -> :ok
    end
  rescue
    error ->
      Logger.warning("queue_keeper_check ledger handler failed: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("queue_keeper_check ledger handler failed: #{inspect({kind, reason})}")
      :ok
  end

  @doc false
  def storage_prefix(repo, opts) do
    case {Keyword.fetch(opts, :prefix), repo.__adapter__()} do
      {{:ok, prefix}, _} when prefix in [nil, false, ""] -> ""
      {{:ok, prefix}, _} -> to_string(prefix)
      {:error, Ecto.Adapters.Postgres} -> "public"
      {:error, _} -> ""
    end
  end

  @doc false
  def prefix_query_opts(repo, opts) do
    case {Keyword.fetch(opts, :prefix), repo.__adapter__()} do
      {{:ok, prefix}, _} when prefix in [nil, false] -> []
      {{:ok, prefix}, _} -> [prefix: prefix]
      {:error, Ecto.Adapters.Postgres} -> [prefix: "public"]
      {:error, _} -> []
    end
  end

  defp process(pid) when is_pid(pid), do: if(Process.alive?(pid), do: pid)
  defp process(name) when is_atom(name), do: Process.whereis(name)
  defp process({:global, _} = name), do: GenServer.whereis(name)
  defp process(other), do: GenServer.whereis(other)

  # -- GenServer ----------------------------------------------------------------------

  @impl true
  def init(opts) do
    repo = Keyword.fetch!(opts, :repo)
    prefix = storage_prefix(repo, opts)
    flush_ms = Keyword.get(opts, :flush_interval, @default_flush_ms)
    max_pending = Keyword.get(opts, :max_pending, @max_pending)
    oban_name = Keyword.get(opts, :oban_name, :all)
    handler_id = {__MODULE__, self()}

    ets =
      :ets.new(__MODULE__, [
        :set,
        :public,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    maybe_sandbox_allow(repo, opts)

    :ok =
      :telemetry.attach_many(
        handler_id,
        @events,
        &__MODULE__.handle_event/4,
        opts[:name] || self()
      )

    if Keyword.get(opts, :backfill, false) do
      safe_backfill(repo, Keyword.put(opts, :prefix, prefix_or_false(prefix, repo)))
    end

    safe_ensure_started(repo, prefix, prefix_query_opts(repo, opts))

    if is_integer(flush_ms) and flush_ms > 0, do: Process.send_after(self(), :flush, flush_ms)

    {:ok,
     %__MODULE__{
       repo: repo,
       prefix: prefix,
       oban_name: oban_name,
       ets: ets,
       handler_id: handler_id,
       flush_ms: flush_ms,
       max_pending: max_pending
     }}
  rescue
    error ->
      Logger.warning("queue_keeper_check ledger failed to start: #{Exception.message(error)}")
      {:ok, :disabled}
  end

  @impl true
  def handle_cast({:event, _meta}, :disabled), do: {:noreply, :disabled}

  def handle_cast({:event, meta}, state) do
    if accept_event?(meta, state) do
      now = event_time(meta)

      for {worker, at, id} <- extract_sightings(meta, now) do
        record(state, worker, at, id)
      end
    end

    {:noreply, state}
  rescue
    error ->
      Logger.warning("queue_keeper_check ledger event failed: #{Exception.message(error)}")
      {:noreply, state}
  end

  def handle_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_call(:flush, _from, :disabled), do: {:reply, {:error, :disabled}, :disabled}

  def handle_call(:flush, _from, state) do
    {:reply, do_flush(state), state}
  end

  @impl true
  def handle_info(:flush, :disabled), do: {:noreply, :disabled}

  def handle_info(:flush, state) do
    _ = do_flush(state)

    if is_integer(state.flush_ms) and state.flush_ms > 0 do
      Process.send_after(self(), :flush, state.flush_ms)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, :disabled), do: :ok

  def terminate(_reason, state) do
    _ = do_flush(state)
    _ = :telemetry.detach(state.handler_id)
    :ok
  end

  # -- recording ----------------------------------------------------------------------

  defp accept_event?(meta, state) do
    conf = conf(meta)
    name_ok?(conf, state.oban_name) and prefix_ok?(conf, state) and repo_ok?(conf, state)
  end

  # Oban typically puts the repo *module* in conf.repo. Compare modules (or a
  # pid registered under that module). Do not call get_dynamic_repo/0 from the
  # ledger process: that would accept whatever happens to be current here.
  # Missing or malformed repo metadata is rejected so a foreign event cannot
  # contaminate this repository's history.
  defp repo_ok?(conf, state) do
    case conf_repo(conf) do
      nil -> false
      event_repo -> same_repo?(event_repo, state.repo)
    end
  end

  defp conf_repo(%{repo: repo}) when not is_nil(repo), do: repo
  defp conf_repo(_), do: nil

  defp same_repo?(left, right) when left == right, do: true

  defp same_repo?(pid, module) when is_pid(pid) and is_atom(module) do
    case Process.info(pid, :registered_name) do
      {:registered_name, ^module} -> true
      _ -> false
    end
  end

  defp same_repo?(_, _), do: false

  defp name_ok?(_conf, :all), do: true
  defp name_ok?(%{name: name}, expected), do: name == expected
  defp name_ok?(_, _), do: true

  defp prefix_ok?(conf, state) do
    event_prefix = conf_prefix(conf, state.repo)
    event_prefix == state.prefix
  end

  defp conf(%{conf: conf}), do: conf
  defp conf(_), do: %{}

  defp conf_prefix(%{prefix: prefix}, _repo) when prefix not in [nil, false, ""],
    do: to_string(prefix)

  defp conf_prefix(_, repo), do: storage_prefix(repo, [])

  defp event_time(%{system_time: t}) when is_integer(t) do
    DateTime.from_unix!(t, :native)
  rescue
    _ -> DateTime.utc_now()
  end

  defp event_time(_), do: DateTime.utc_now()

  defp extract_sightings(meta, now) do
    jobs = List.wrap(meta[:job]) ++ List.wrap(meta[:jobs])
    from_jobs = Enum.flat_map(jobs, &sighting_from_job(&1, now))

    from_changesets =
      meta
      |> Map.get(:changesets, [])
      |> List.wrap()
      |> Enum.flat_map(&sighting_from_changeset(&1, now))

    # Unique insert_all conflicts may be omitted from returned jobs; keep the
    # changeset workers too. ETS keeps the later timestamp per worker.
    from_jobs ++ from_changesets
  end

  defp sighting_from_job(nil, _now), do: []

  defp sighting_from_job(job, now) do
    case worker_name(job) do
      nil ->
        []

      worker ->
        at = if conflict?(job), do: now, else: inserted_at(job) || now
        [{worker, at, job_id(job)}]
    end
  end

  defp sighting_from_changeset(%Ecto.Changeset{} = cs, now) do
    worker = changeset_worker(cs)
    if worker, do: [{worker, now, nil}], else: []
  end

  defp sighting_from_changeset(_, _), do: []

  defp worker_name(%{worker: w}) when is_binary(w), do: w
  defp worker_name(%{worker: w}) when is_atom(w), do: module_name(w)
  defp worker_name(%{"worker" => w}) when is_binary(w), do: w
  defp worker_name(_), do: nil

  defp changeset_worker(%Ecto.Changeset{} = cs) do
    case Ecto.Changeset.get_field(cs, :worker) do
      w when is_binary(w) -> w
      w when is_atom(w) and not is_nil(w) -> module_name(w)
      _ -> nil
    end
  end

  defp module_name(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> rest -> rest
      name -> name
    end
  end

  defp conflict?(%{conflict?: true}), do: true
  defp conflict?(%{"conflict?" => true}), do: true
  defp conflict?(_), do: false

  defp inserted_at(%{inserted_at: %DateTime{} = t}), do: t
  defp inserted_at(%{inserted_at: %NaiveDateTime{} = t}), do: DateTime.from_naive!(t, "Etc/UTC")
  defp inserted_at(_), do: nil

  defp job_id(%{id: id}) when is_integer(id), do: id
  defp job_id(%{"id" => id}) when is_integer(id), do: id
  defp job_id(_), do: nil

  defp record(state, worker, at, id) do
    key = {state.prefix, worker}

    case :ets.lookup(state.ets, key) do
      [{^key, prev_at, _prev_id}] ->
        if later?(at, prev_at), do: :ets.insert(state.ets, {key, at, id})
        :ok

      [] ->
        if :ets.info(state.ets, :size) >= state.max_pending do
          send(self(), :flush)

          Logger.warning(
            "queue_keeper_check ledger pending cap (#{state.max_pending}) reached; dropping new worker #{worker} until flush"
          )
        else
          :ets.insert(state.ets, {key, at, id})
        end
    end
  end

  defp later?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) != :lt
  defp later?(_, _), do: true

  # -- flush / SQL --------------------------------------------------------------------

  defp do_flush(state) do
    rows = :ets.tab2list(state.ets)

    if rows != [] do
      qopts = prefix_query_opts(state.repo, prefix: prefix_or_false(state.prefix, state.repo))
      payload = Enum.map(rows, fn {{_p, worker}, at, id} -> {worker, at, id} end)
      ensure_started(state.repo, state.prefix, DateTime.utc_now(), qopts)
      upsert_rows(state.repo, state.prefix, payload, qopts)

      # Drop only the exact tuples we flushed so a newer sighting that arrived
      # mid-upsert stays in ETS.
      Enum.each(rows, fn {key, at, id} ->
        :ets.select_delete(state.ets, [{{key, at, id}, [], [true]}])
      end)
    else
      qopts = prefix_query_opts(state.repo, prefix: prefix_or_false(state.prefix, state.repo))
      ensure_started(state.repo, state.prefix, DateTime.utc_now(), qopts)
    end

    :ok
  rescue
    error ->
      Logger.warning("queue_keeper_check ledger flush failed: #{Exception.message(error)}")
      {:error, error}
  end

  defp safe_backfill(repo, opts) do
    backfill(repo, opts)
  rescue
    error ->
      Logger.warning("queue_keeper_check ledger backfill failed: #{Exception.message(error)}")
      :ok
  end

  defp safe_ensure_started(repo, prefix, qopts) do
    ensure_started(repo, prefix, DateTime.utc_now(), qopts)
  rescue
    error ->
      Logger.warning(
        "queue_keeper_check ledger could not record started_at: #{Exception.message(error)}"
      )

      :ok
  end

  defp maybe_sandbox_allow(repo, opts) do
    owner = Keyword.get(opts, :sandbox)

    if is_pid(owner) and Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      Ecto.Adapters.SQL.Sandbox.allow(repo, owner, self())
    end
  end

  defp prefix_or_false("", repo) do
    if repo.__adapter__() == Ecto.Adapters.Postgres, do: "public", else: false
  end

  defp prefix_or_false(prefix, _repo), do: prefix

  defp row_from_agg([worker, at, id]), do: {worker, to_dt(at), id}
  defp row_from_agg({worker, at, id}), do: {worker, to_dt(at), id}

  defp to_dt(%DateTime{} = t), do: t
  defp to_dt(%NaiveDateTime{} = t), do: DateTime.from_naive!(t, "Etc/UTC")

  defp to_dt(t) when is_binary(t) do
    case DateTime.from_iso8601(t) do
      {:ok, dt, _offset} ->
        dt

      _ ->
        case NaiveDateTime.from_iso8601(t) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          _ -> DateTime.utc_now()
        end
    end
  end

  defp to_dt(_), do: DateTime.utc_now()

  defp ensure_started(repo, prefix, started_at, qopts) do
    adapter = repo.__adapter__()
    table = quote_table(adapter, qopts, @meta)
    sql = insert_meta_sql(adapter, table)
    _ = repo.query!(sql, [prefix, started_at], query_opts())
    :ok
  end

  defp insert_meta_sql(Ecto.Adapters.Postgres, table) do
    """
    INSERT INTO #{table} (prefix, started_at)
    VALUES ($1, $2)
    ON CONFLICT (prefix) DO UPDATE SET
      started_at = LEAST(#{@meta}.started_at, EXCLUDED.started_at)
    """
  end

  defp insert_meta_sql(Ecto.Adapters.SQLite3, table) do
    """
    INSERT INTO #{table} (prefix, started_at)
    VALUES (?, ?)
    ON CONFLICT (prefix) DO UPDATE SET
      started_at = MIN(#{@meta}.started_at, excluded.started_at)
    """
  end

  defp insert_meta_sql(Ecto.Adapters.MyXQL, table) do
    """
    INSERT INTO #{table} (prefix, started_at)
    VALUES (?, ?)
    ON DUPLICATE KEY UPDATE
      started_at = LEAST(started_at, VALUES(started_at))
    """
  end

  defp upsert_rows(_repo, _prefix, [], _qopts), do: :ok

  defp upsert_rows(repo, prefix, rows, qopts) do
    adapter = repo.__adapter__()
    table = quote_table(adapter, qopts, @sightings)

    Enum.each(Enum.chunk_every(rows, @upsert_chunk), fn chunk ->
      {sql, params} = upsert_sql(adapter, table, prefix, chunk)
      repo.query!(sql, params, query_opts())
    end)

    :ok
  end

  defp upsert_sql(Ecto.Adapters.Postgres, table, prefix, rows) do
    {values, params, _} =
      Enum.reduce(rows, {[], [], 1}, fn {worker, at, id}, {vals, params, i} ->
        line = "($#{i}, $#{i + 1}, $#{i + 2}, $#{i + 3})"
        {vals ++ [line], params ++ [prefix, worker, at, id], i + 4}
      end)

    sql = """
    INSERT INTO #{table} (prefix, worker, last_inserted_at, last_job_id)
    VALUES #{Enum.join(values, ", ")}
    ON CONFLICT (prefix, worker) DO UPDATE SET
      last_inserted_at = GREATEST(#{@sightings}.last_inserted_at, EXCLUDED.last_inserted_at),
      last_job_id = CASE
        WHEN EXCLUDED.last_inserted_at >= #{@sightings}.last_inserted_at
        THEN EXCLUDED.last_job_id
        ELSE #{@sightings}.last_job_id
      END
    """

    {sql, params}
  end

  defp upsert_sql(Ecto.Adapters.SQLite3, table, prefix, rows) do
    {values, params} =
      Enum.reduce(rows, {[], []}, fn {worker, at, id}, {vals, params} ->
        {vals ++ ["(?, ?, ?, ?)"], params ++ [prefix, worker, at, id]}
      end)

    sql = """
    INSERT INTO #{table} (prefix, worker, last_inserted_at, last_job_id)
    VALUES #{Enum.join(values, ", ")}
    ON CONFLICT (prefix, worker) DO UPDATE SET
      last_inserted_at = MAX(#{@sightings}.last_inserted_at, excluded.last_inserted_at),
      last_job_id = CASE
        WHEN excluded.last_inserted_at >= #{@sightings}.last_inserted_at
        THEN excluded.last_job_id
        ELSE #{@sightings}.last_job_id
      END
    """

    {sql, params}
  end

  defp upsert_sql(Ecto.Adapters.MyXQL, table, prefix, rows) do
    {values, params} =
      Enum.reduce(rows, {[], []}, fn {worker, at, id}, {vals, params} ->
        {vals ++ ["(?, ?, ?, ?)"], params ++ [prefix, worker, at, id]}
      end)

    sql = """
    INSERT INTO #{table} (prefix, worker, last_inserted_at, last_job_id)
    VALUES #{Enum.join(values, ", ")}
    ON DUPLICATE KEY UPDATE
      last_inserted_at = GREATEST(last_inserted_at, VALUES(last_inserted_at)),
      last_job_id = IF(VALUES(last_inserted_at) >= last_inserted_at, VALUES(last_job_id), last_job_id)
    """

    {sql, params}
  end

  defp ledger_tables_status(repo, Ecto.Adapters.Postgres, qopts) do
    schema = qopts[:prefix] || "public"
    sql = "SELECT to_regclass($1), to_regclass($2)"

    case repo.query!(sql, ["#{schema}.#{@meta}", "#{schema}.#{@sightings}"], query_opts()) do
      %{rows: [[meta, sightings]]} when is_nil(meta) or is_nil(sightings) -> :absent
      %{rows: [[_, _]]} -> :present
    end
  end

  defp ledger_tables_status(repo, Ecto.Adapters.SQLite3, _qopts) do
    sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN (?, ?)"
    names = table_names(repo.query!(sql, [@meta, @sightings], query_opts()))
    if @meta in names and @sightings in names, do: :present, else: :absent
  end

  defp ledger_tables_status(repo, Ecto.Adapters.MyXQL, _qopts) do
    sql = """
    SELECT table_name FROM information_schema.tables
    WHERE table_schema = DATABASE() AND table_name IN (?, ?)
    """

    names = table_names(repo.query!(sql, [@meta, @sightings], query_opts()))
    if @meta in names and @sightings in names, do: :present, else: :absent
  end

  defp table_names(%{rows: rows}), do: Enum.map(rows, fn [name] -> to_string(name) end)

  defp fetch_started_at(repo, prefix, adapter, qopts) do
    table = quote_table(adapter, qopts, @meta)
    {sql, params} = select_eq(adapter, "SELECT started_at FROM #{table} WHERE prefix = ", prefix)

    case repo.query!(sql, params, query_opts()) do
      %{rows: [[at]]} -> {:ok, to_dt(at)}
      %{rows: []} -> :absent
    end
  end

  defp fetch_sightings(repo, prefix, adapter, qopts) do
    table = quote_table(adapter, qopts, @sightings)

    {sql, params} =
      select_eq(
        adapter,
        "SELECT worker, last_inserted_at, last_job_id FROM #{table} WHERE prefix = ",
        prefix
      )

    repo.query!(sql, params, query_opts()).rows
    |> Map.new(fn [worker, at, id] -> {worker, {to_dt(at), id, 0}} end)
  end

  defp select_eq(Ecto.Adapters.Postgres, head, prefix), do: {head <> "$1", [prefix]}
  defp select_eq(_, head, prefix), do: {head <> "?", [prefix]}

  defp quote_table(Ecto.Adapters.Postgres, qopts, name) do
    schema = qopts[:prefix] || "public"
    ~s{"#{schema}"."#{name}"}
  end

  defp quote_table(_, _qopts, name), do: name

  defp query_opts, do: [timeout: 30_000]
end
