defmodule QueueKeeperCheck.DeadCode do
  @moduledoc """
  Static scan for Oban worker modules that have no compile-time call sites and
  are not listed in Oban (or Oban Pro) cron config.

  This answers a different question from `:dead_workers`: not "has this worker
  been enqueued in the last N days?" but "does anything in the compiled code
  appear to enqueue it?" It does not need job history or a longer Pruner
  `max_age`.

  The scan needs the host project **compiled** (`mix compile`). It walks
  `Application.spec/2` modules (with `Code.ensure_loaded/1`, not
  `:code.all_loaded/0`) and looks up callers from each compiled beam's debug
  info, the same class of data `mix xref callers` uses. `config.exs` crontab
  entries are not part of that graph, so crontab is parsed separately from
  loaded Application env.

  **False positives (reported as dead, but still used):** a worker enqueued only
  through dynamic dispatch (`Module.concat`, `apply/3` on a string or variable,
  `Oban.insert` with a worker name built at runtime, or a name stored in the
  database). Those have no static call site.

  **False negatives (not reported, but unused):** none that we know of for a
  worker that is still referenced by a module atom in compiled code, even if
  that reference is `apply(MyApp.Worker, :new, ...)`.

  Runtime-only cron (Oban Pro DynamicCron / `Oban.Pro.Cron` rules added in the
  database and not present in config) is **not** scanned; those workers can be
  listed in `:ignore`.

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
  """
  def scan(opts \\ []) when is_list(opts) do
    ignore = MapSet.new(List.wrap(opts[:ignore]))
    extra_cron = MapSet.new(List.wrap(opts[:cron]))
    cron = MapSet.union(cron_workers_from_env(), extra_cron)

    discovered = discover_workers(opts[:apps])
    known = List.wrap(opts[:known])
    workers = Enum.uniq(discovered ++ known)

    callers = opts[:callers] || callers_of(workers)

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
          %{worker: worker, status: :dead, reason: :no_call_sites, files: []}
      end
    end)
  end

  @doc "Worker names with no static callers and not in cron."
  def dead_workers(opts \\ []) do
    for %{status: :dead, worker: worker} <- scan(opts), do: worker
  end

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

  defp callers_of(workers) do
    wanted =
      Map.new(workers, fn name ->
        {Module.concat([name]), name}
      end)

    Enum.reduce(compile_beams(), %{}, fn path, acc ->
      case referenced_modules(path) do
        {:ok, file, mods} ->
          Enum.reduce(mods, acc, fn mod, acc ->
            case Map.get(wanted, mod) do
              nil ->
                acc

              name ->
                Map.update(acc, name, [file], fn files -> Enum.uniq([file | files]) end)
            end
          end)

        :error ->
          acc
      end
    end)
  end

  defp compile_beams do
    paths =
      if function_exported?(Mix.Project, :compile_path, 0) do
        umbrella =
          if function_exported?(Mix.Project, :apps_paths, 0) and Mix.Project.umbrella?() do
            for {app, _} <- Mix.Project.apps_paths() do
              Mix.Project.in_project(app, "apps/#{app}", fn _ -> Mix.Project.compile_path() end)
            end
          else
            []
          end

        [Mix.Project.compile_path() | umbrella]
      else
        []
      end

    for dir <- Enum.uniq(Enum.reject(paths, &is_nil/1)),
        File.dir?(dir),
        file <- File.ls!(dir),
        String.ends_with?(file, ".beam"),
        do: Path.join(dir, file)
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
      _ -> :error
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
