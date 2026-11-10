defmodule QueueKeeperCheck.DeadCode do
  @moduledoc """
  Static scan for Oban worker modules that have no compile-time call sites and
  are not listed in Oban (or Oban Pro) cron config.

  This answers a different question from `:dead_workers`: not "has this worker
  been enqueued in the last N days?" but "does anything in the compiled code
  appear to enqueue it?" It does not need job history or a longer Pruner
  `max_age`. Absence of a static caller is **not** proof the worker is unused:
  jobs may still be scheduled, enqueued dynamically, or referenced from a beam
  this scan could not read.

  The scan needs the host project **compiled** (`mix compile`). It walks
  `Application.spec/2` modules (with `Code.ensure_loaded/1`, not
  `:code.all_loaded/0`) and looks up callers from each compiled beam's debug
  info, the same class of data `mix xref callers` uses. `config.exs` crontab
  entries are not part of that graph, so crontab is parsed separately from
  loaded Application env.

  Workers with no static callers are classified as `:review_candidate`, not as
  proven dead code. `scan_report/1` also returns coverage: beams scanned, beams
  missing debug info, empty compile paths, and whether results are complete.

  **Review candidates that may still be used:** a worker enqueued only through
  dynamic dispatch (`Module.concat`, `apply/3` on a string or variable,
  `Oban.insert` with a worker name built at runtime, or a name stored in the
  database); a worker whose only callers live in a beam without debug info;
  runtime-only cron. Those have no static call site this scan can see.

  **Limitations that can hide a real caller (false "no call sites"):** missing
  BEAM debug info, compile paths the scan did not walk, and dynamic dispatch.
  A module atom still present in compiled debug info is treated as a caller,
  even if that reference is `apply(MyApp.Worker, :new, ...)`.

  Runtime-only cron (Oban Pro DynamicCron / `Oban.Pro.Cron` rules added in the
  database and not present in config) is **not** scanned; those workers can be
  listed in `:ignore`. Oban Pro cron parsing beyond Application env is
  unverified (no Pro license in this project's tests).

  Used by `mix queue_keeper.dead_code`.
  """

  @otp_apps ~w(kernel stdlib compiler elixir elixirc logger mix eex iex ex_unit
    inets ssl public_key crypto asn1 syntax_tools sasl wx observer runtime_tools
    os_mon et debugger edoc erl_docgen ftp tftp common_test dialyzer typerex
    parsetools reltool erts mnesia snmp xmerl)a

  @doc """
  Run the scan.

  Options:

  * `:apps` — application names to search for workers (default: loaded non-OTP
    apps, excluding `:oban`, `:ecto`, `:ecto_sql` and adapter apps)
  * `:ignore` — worker name strings to skip
  * `:known` — extra worker name strings to include even if discover misses them
  * `:cron` — extra worker name strings to treat as cron (in addition to config)
  * `:callers` — optional `%{worker_name => [file]}` to inject in tests
  * `:beam_roots` — directories of `.beam` files to walk for callers (default:
    the Mix compile path, plus each umbrella app's compile path). Intended for
    tests and for running the scan without Mix.Project
  * `:beam_paths` — extra `.beam` files to include in the caller walk
  """
  def scan(opts \\ []) when is_list(opts) do
    %{workers: workers} = scan_report(opts)
    workers
  end

  @doc """
  Like `scan/1`, plus a coverage map so callers can tell incomplete discovery
  from a confident empty caller list.

  Coverage keys: `:beams_scanned`, `:beams_ok`, `:beams_missing_debug_info`,
  `:beams_unreadable`, `:compile_paths_empty`, `:apps`, `:complete?`.
  `complete?` is true only when at least one beam was scanned and none were
  missing debug info or unreadable.
  """
  def scan_report(opts \\ []) when is_list(opts) do
    ignore = MapSet.new(List.wrap(opts[:ignore]))
    extra_cron = MapSet.new(List.wrap(opts[:cron]))
    cron = MapSet.union(cron_workers_from_env(), extra_cron)

    apps = opts[:apps] || default_apps()
    discovered = discover_workers(apps)
    known = List.wrap(opts[:known])
    workers = Enum.uniq(discovered ++ known)

    {callers, coverage} =
      case opts[:callers] do
        nil ->
          callers_of(workers, opts)

        injected ->
          {injected, coverage(opts, _scanned = 0, _ok = 0, _missing = 0, _bad = 0)}
      end

    coverage =
      coverage
      |> Map.put(:apps, apps)
      |> Map.put(:workers_discovered, length(discovered))
      |> Map.put(:workers_known, length(known))
      |> Map.put(:cron_from_env, MapSet.size(cron_workers_from_env()))

    results =
      workers
      |> Enum.reject(&MapSet.member?(ignore, &1))
      |> Enum.sort()
      |> Enum.map(fn worker ->
        files = Map.get(callers, worker, [])
        in_cron? = MapSet.member?(cron, worker)

        cond do
          files != [] ->
            %{worker: worker, status: :live, reason: :callers, files: files}

          in_cron? ->
            %{worker: worker, status: :live, reason: :cron, files: []}

          true ->
            %{worker: worker, status: :review_candidate, reason: :no_call_sites, files: []}
        end
      end)

    %{workers: results, coverage: coverage}
  end

  @doc """
  Worker names with no static callers and not in cron.

  These are review candidates, not proven dead code. Prefer this name over
  `dead_workers/1`.
  """
  def review_candidates(opts \\ []) do
    for %{status: :review_candidate, worker: worker} <- scan(opts), do: worker
  end

  @doc """
  Same as `review_candidates/1`. Kept so existing call sites keep working;
  the status atom returned by `scan/1` is `:review_candidate`, not `:dead`.
  """
  def dead_workers(opts \\ []), do: review_candidates(opts)

  @doc false
  def discover_workers(apps) do
    apps = apps || default_apps()

    for app <- apps,
        modules when is_list(modules) <- [Application.spec(app, :modules)],
        mod <- modules,
        match?({:module, _}, Code.ensure_loaded(mod)),
        worker_module?(mod),
        do: module_name(mod)
  end

  defp default_apps do
    otp_root = :code.root_dir() |> List.to_string()

    skip =
      MapSet.new(
        [
          :oban,
          :ecto,
          :ecto_sql,
          :postgrex,
          :myxql,
          :exqlite,
          :ecto_sqlite3,
          :jason,
          :telemetry,
          :db_connection,
          :decimal,
          :queue_keeper_check
        ] ++ @otp_apps
      )

    for {app, _, _} <- Application.loaded_applications(),
        not MapSet.member?(skip, app),
        lib_dir = :code.lib_dir(app),
        is_list(lib_dir),
        not String.starts_with?(List.to_string(lib_dir), otp_root),
        do: app
  end

  defp worker_module?(mod) do
    function_exported?(mod, :perform, 1) and function_exported?(mod, :__opts__, 0) and
      is_list(mod.__opts__()) and Keyword.has_key?(mod.__opts__(), :queue)
  rescue
    _ -> false
  end

  defp module_name(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> rest -> rest
      name -> name
    end
  end

  @doc false
  def cron_workers_from_env do
    Application.loaded_applications()
    |> Enum.flat_map(fn {app, _, _} ->
      for {_key, val} <- Application.get_all_env(app), do: extract_cron_workers(val)
    end)
    |> List.flatten()
    |> Enum.uniq()
    |> MapSet.new()
  end

  defp extract_cron_workers(val) when is_list(val) do
    cond do
      Keyword.keyword?(val) ->
        crontab_workers(Keyword.get(val, :crontab, [])) ++
          extract_cron_workers(Keyword.get(val, :cron)) ++
          Enum.flat_map(Keyword.get(val, :plugins, []), &extract_cron_workers/1)

      true ->
        Enum.flat_map(val, &extract_cron_workers/1)
    end
  end

  defp extract_cron_workers({mod, opts}) when is_atom(mod) and is_list(opts),
    do: extract_cron_workers(opts)

  defp extract_cron_workers(_), do: []

  defp crontab_workers(list) when is_list(list) do
    Enum.flat_map(list, fn
      {_expr, mod} when is_atom(mod) -> [module_name(mod)]
      {_expr, mod, _opts} when is_atom(mod) -> [module_name(mod)]
      {_expr, name} when is_binary(name) -> [name]
      {_expr, name, _opts} when is_binary(name) -> [name]
      _ -> []
    end)
  end

  defp crontab_workers(_), do: []

  defp callers_of(workers, opts) do
    paths = compile_beams(opts)

    # Walk beams first so debug_info decoding can intern module atoms before
    # we resolve `:known` names. Never create atoms from worker-name strings
    # (`Module.concat` / `String.to_atom`); use existing atoms only.
    {callers_acc, scanned, ok, missing, bad} =
      Enum.reduce(paths, {%{}, 0, 0, 0, 0}, fn path, {acc, scanned, ok, missing, bad} ->
        scanned = scanned + 1

        case referenced_modules(path) do
          {:ok, file, mods} ->
            acc =
              Enum.reduce(mods, acc, fn mod, acc ->
                Map.update(acc, mod, [file], fn files -> Enum.uniq([file | files]) end)
              end)

            {acc, scanned, ok + 1, missing, bad}

          :missing_debug_info ->
            {acc, scanned, ok, missing + 1, bad}

          :error ->
            {acc, scanned, ok, missing, bad + 1}
        end
      end)

    wanted =
      workers
      |> Enum.flat_map(fn name ->
        case existing_elixir_module(name) do
          nil -> []
          mod -> [{mod, name}]
        end
      end)
      |> Map.new()

    callers =
      Enum.reduce(wanted, %{}, fn {mod, name}, acc ->
        case Map.get(callers_acc, mod) do
          nil -> acc
          files -> Map.put(acc, name, files)
        end
      end)

    {callers, coverage(opts, scanned, ok, missing, bad)}
  end

  defp existing_elixir_module(name) when is_binary(name) do
    try do
      String.to_existing_atom("Elixir." <> name)
    rescue
      ArgumentError ->
        nil
    end
  end

  defp coverage(_opts, scanned, ok, missing, bad) do
    %{
      beams_scanned: scanned,
      beams_ok: ok,
      beams_missing_debug_info: missing,
      beams_unreadable: bad,
      compile_paths_empty: scanned == 0,
      complete?: scanned > 0 and missing == 0 and bad == 0
    }
  end

  defp compile_beams(opts) do
    dirs =
      case opts[:beam_roots] do
        nil -> default_compile_dirs()
        roots -> List.wrap(roots)
      end

    from_dirs =
      for dir <- Enum.uniq(Enum.reject(dirs, &is_nil/1)),
          File.dir?(dir),
          file <- File.ls!(dir),
          String.ends_with?(file, ".beam"),
          do: Path.join(dir, file)

    extras =
      for path <- List.wrap(opts[:beam_paths]),
          is_binary(path),
          File.regular?(path),
          do: path

    Enum.uniq(from_dirs ++ extras)
  end

  defp default_compile_dirs do
    if function_exported?(Mix.Project, :compile_path, 0) do
      umbrella =
        if function_exported?(Mix.Project, :apps_paths, 0) and Mix.Project.umbrella?() do
          for {app, path} <- Mix.Project.apps_paths() do
            Mix.Project.in_project(app, path, fn _ -> Mix.Project.compile_path() end)
          end
        else
          []
        end

      [Mix.Project.compile_path() | umbrella]
    else
      []
    end
  end

  defp referenced_modules(path) do
    with {:ok, {mod, [debug_info: debug_info]}} <-
           :beam_lib.chunks(to_charlist(path), [:debug_info]),
         {:debug_info_v1, backend, data} <- debug_info,
         {:ok, %{definitions: defs, relative_file: file}} <-
           safe_debug_info(backend, mod, data) do
      mods =
        defs
        |> Enum.flat_map(&walk_def/1)
        |> Enum.uniq()
        |> Enum.reject(&(&1 == mod))

      {:ok, file || source_from_mod(mod) || path, mods}
    else
      {:error, :beam_lib, {:missing_chunk, _, chunk}}
      when chunk in [:debug_info, ~c"Dbgi"] ->
        :missing_debug_info

      {:error, :beam_lib, {:no_debug_info, _}} ->
        :missing_debug_info

      {:ok, {_mod, chunks}} ->
        if Keyword.has_key?(chunks, :debug_info), do: :error, else: :missing_debug_info

      _ ->
        :error
    end
  end

  defp safe_debug_info(backend, mod, data) do
    case backend.debug_info(:elixir_v1, mod, data, []) do
      {:ok, info} -> {:ok, Map.merge(%{relative_file: nil}, info)}
      other -> other
    end
  rescue
    _ -> :error
  end

  defp source_from_mod(mod) do
    case :code.which(mod) do
      path when is_list(path) -> List.to_string(path)
      _ -> nil
    end
  end

  defp walk_def({_fun, _kind, _meta, clauses}), do: Enum.flat_map(clauses, &walk_clause/1)
  defp walk_def(_), do: []

  defp walk_clause({_meta, args, _guards, body}), do: walk_expr(args) ++ walk_expr(body)
  defp walk_clause(_), do: []

  # &Mod.fun/arity
  defp walk_expr({:&, _, [{:/, _, [{{:., _, [mod, _fun]}, _, []}, _arity]}]}) when is_atom(mod),
    do: [mod]

  # Mod.fun(...)
  defp walk_expr({{:., _, [mod, _fun]}, _, args}) when is_atom(mod),
    do: [mod | walk_expr(args)]

  # %Mod{...}
  defp walk_expr({:%, _, [mod, map]}) when is_atom(mod), do: [mod | walk_expr(map)]

  # alias / Module.concat(Elixir, "...") we cannot recover; skip
  defp walk_expr({_, _, args}) when is_list(args), do: walk_expr(args)
  defp walk_expr({_, args}) when is_list(args), do: walk_expr(args)
  defp walk_expr(list) when is_list(list), do: Enum.flat_map(list, &walk_expr/1)
  defp walk_expr(tuple) when is_tuple(tuple), do: walk_expr(Tuple.to_list(tuple))

  defp walk_expr(mod) when is_atom(mod) do
    case Atom.to_string(mod) do
      "Elixir." <> _ -> [mod]
      _ -> []
    end
  end

  defp walk_expr(_), do: []
end
