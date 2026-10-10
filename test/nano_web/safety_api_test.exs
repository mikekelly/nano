defmodule NanoWeb.SafetyApiTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  @endpoint NanoWeb.Endpoint

  test "operator status and independent probe are discoverable and secret-free" do
    status = build_conn() |> get("/api/safety") |> json_response(200)
    assert is_boolean(status["protected"])
    assert status == Jason.decode!(Jason.encode!(Nano.Ops.safety()))
    health = build_conn() |> get("/api/safety/health") |> json_response(200)
    assert health["responsive"] == true
    assert health["boot"] == System.pid()
    assert is_boolean(health["model_served"])
    refute Map.has_key?(health, "credentials")
  end
end
