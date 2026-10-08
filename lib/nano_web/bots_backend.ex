defmodule NanoWeb.BotsBackend do
  @moduledoc """
  A narrow LiveView boundary around the Bots facade. Process exits and its explicit
  startup-unavailable error become `throw(:bots_service_unavailable)`, caught by
  BotsLive at lifecycle/event boundaries. Business errors remain return values;
  template exceptions and unrelated programming errors are never rescued.
  """

  for {name, arity} <- [
        snapshot: 1,
        session: 2,
        subscribe: 1,
        create_bot: 2,
        create_session: 2,
        say: 3,
        stop: 2,
        reply: 3,
        preferences: 2
      ] do
    args = Macro.generate_arguments(arity, __MODULE__)
    def unquote(name)(unquote_splicing(args)), do: invoke(unquote(name), [unquote_splicing(args)])
  end

  defp invoke(name, args) do
    apply(Bots, name, args)
  rescue
    error in RuntimeError ->
      if String.starts_with?(Exception.message(error), "Bots service unavailable:") do
        throw(:bots_service_unavailable)
      else
        reraise error, __STACKTRACE__
      end
  catch
    :exit, _ -> throw(:bots_service_unavailable)
  end
end
