defmodule MecksUnit.Case do
  defmacro __using__(_opts) do
    quote do
      import MecksUnit.Case
      Module.register_attribute(__MODULE__, :mocks, accumulate: true, persist: false)
      @mock_index 0
    end
  end

  defmacro defmock({_alias, _meta, name}, do: block) do
    quote do
      name =
        Module.concat([Enum.join([__MODULE__, @mock_index]), unquote_splicing(List.wrap(name))])

      block = unquote(Macro.escape(block))
      @mocks {name, block}
    end
  end

  defmacro mocked_test(message, pattern \\ nil, block) do
    args = if pattern == nil, do: [message], else: [message, pattern]

    quote do
      MecksUnit.define_mocks(@mocks, __MODULE__, @mock_index)

      test unquote_splicing(args) do
        mock_env = Enum.join([__MODULE__, @mock_index])
        MecksUnit.Server.register_mock_env(self(), mock_env)
        unquote(block)
        MecksUnit.Server.unregister_mock_env(self())
      end
    end
  end

  defmacro called({{:., _, [module, func]}, _, args}) do
    quote do
      MecksUnit.called(unquote(module), unquote(func), unquote(replace_ignore_pattern(args)))
    end
  end

  defmacro assert_called({{:., _, [module, func]}, _, args}) do
    quote do
      unless MecksUnit.called(
               unquote(module),
               unquote(func),
               unquote(replace_ignore_pattern(args))
             ) do
        calls =
          unquote(module)
          |> MecksUnit.history(unquote(func))
          |> Enum.reduce([""], fn {p, {m, f, a}, r}, calls ->
            p = inspect(p)
            m = String.replace("#{m}", "Elixir.", "")
            a = String.slice(inspect(a), 1..-2)
            r = inspect(r)
            ["#{p} #{m}.#{f}(#{a}) #=> #{r}"]
          end)

        raise ExUnit.AssertionError,
          message: "Expected call but did not receive it. Calls which were received:\n#{calls}"
      end
    end
  end

  defp replace_ignore_pattern(args) do
    for arg <- args do
      case arg do
        {:_, _, nil} -> :_
        tuple -> tuple
      end
    end
  end
end
