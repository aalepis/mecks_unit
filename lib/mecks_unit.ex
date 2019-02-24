defmodule MecksUnit do
  @moduledoc false

  def mock do
    functions =
      test_file_patterns()
      |> Enum.map(fn pattern ->
        pattern
        |> Path.wildcard()
        |> Enum.map(&extract_mock_functions/1)
      end)
      |> List.flatten()
      |> Enum.uniq()

    MecksUnit.Unloader.register()
    MecksUnit.Server.register_mocked(functions)

    mock_functions(functions)
  end

  defp test_file_patterns do
    System.argv()
    |> Enum.slice(1..-1)
    |> case do
      [] -> ["test/**/*.exs"]
      patterns -> patterns
    end
    |> Enum.map(fn pattern ->
      pattern = Regex.replace(~r/\.exs:\d*/, pattern, ".exs")

      if String.contains?(pattern, ".exs") do
        pattern
      else
        pattern <> "**/*.exs"
      end
    end)
  end

  defp extract_mock_functions(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> Macro.traverse([], fn node, acc -> {node, acc} end, fn node, acc ->
      case node do
        {:defmock, _, [{:__aliases__, _meta, name}, [do: block]]} ->
          mocked_functions =
            name
            |> Module.concat()
            |> extract_function_heads(block)

          {node, acc ++ mocked_functions}

        node ->
          {node, acc}
      end
    end)
    |> elem(1)
  end

  defp extract_function_heads(module, {:__block__, [], ast}) do
    extract_function_heads(module, ast)
  end

  defp extract_function_heads(module, ast) do
    ast
    |> List.wrap()
    |> Enum.map(fn {:def, _, [{func, _meta, args} | _tail]} ->
      {module, func, args |> List.wrap() |> length()}
    end)
  end

  defp mock_functions(functions) do
    Enum.each(functions, fn {module, func, arity} ->
      mock_function = to_mock_function(module, func, arity)
      :meck.expect(module, func, mock_function)
    end)
  end

  defp to_mock_function(module, func, arity) do
    arguments = Macro.generate_arguments(arity, :"Elixir")

    module =
      case module do
        [_head | _tail] = module -> module
        module -> [module]
      end

    quote do
      fn unquote_splicing(arguments) ->
        mock_env = MecksUnit.Server.running(self())
        mock_module = Module.concat([mock_env, unquote_splicing(module)])

        arguments = [unquote_splicing(arguments)]

        passthrough = fn arguments ->
          :meck.passthrough(arguments)
        end

        if mock_env && function_exported?(mock_module, unquote(func), unquote(arity)) do
          try do
            case apply(mock_module, unquote(func), arguments) do
              {:passthrough, arguments} -> passthrough.(arguments)
              :passthrough -> passthrough.(arguments)
              returned -> returned
            end
          rescue
            FunctionClauseError ->
              passthrough.(arguments)
          end
        else
          passthrough.(arguments)
        end
      end
    end
    |> Code.eval_quoted()
    |> elem(0)
  end

  def define_mocks(mocks, _test_module, _mock_index) do
    Enum.each(mocks, fn {mock_module, block} ->
      if !function_exported?(mock_module, :__info__, 1) do
        Code.eval_quoted({:defmodule, [import: Kernel], [mock_module, [do: block]]})
      end
    end)
  end

  def called(module, func, arguments) do
    module
    |> history(func)
    |> Enum.any?(fn {_pid, {_module, _func, args}, _returned} ->
      if length(arguments) == length(args) do
        arguments
        |> Enum.with_index()
        |> Enum.all?(fn {arg, index} ->
          arg == :_ || Enum.at(args, index) == arg
        end)
      end
    end)
  end

  def history(module, func) do
    pid = self()

    module
    |> :meck.history()
    |> Enum.reduce([], fn
      {^pid, {^module, ^func, _args}, _returned} = call, calls ->
        calls ++ [call]

      _, calls ->
        calls
    end)
  end
end
