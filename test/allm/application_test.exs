defmodule ALLM.ApplicationTest do
  use ExUnit.Case, async: true

  describe "ALLM.Application supervises ALLM.Finch" do
    test "Application.started_applications/0 lists :allm and :finch" do
      started = Application.started_applications() |> Enum.map(&elem(&1, 0))
      assert :allm in started
      assert :finch in started
    end

    test "Process.whereis(ALLM.Finch) returns a non-nil pid after app start" do
      pid = Process.whereis(ALLM.Finch)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "the ALLM.Finch default pool uses protocol :http1 (load-bearing per spec §7.2)" do
      # Finch stashes its resolved configuration in the Registry it owns;
      # `Registry.meta(name, :config)` is the documented introspection
      # surface we can rely on without poking at gen_server state.
      {:ok, %{default_pool_config: %{conn_opts: conn_opts}}} =
        Registry.meta(ALLM.Finch, :config)

      assert Keyword.get(conn_opts, :protocols) == [:http1],
             "expected ALLM.Finch's default pool to be pinned to :http1; got #{inspect(conn_opts)}"
    end
  end
end
