defmodule ALLM.Keys.StoreTest do
  # async: false — this suite toggles Application env (:load_dotenv, :dotenv_path)
  # and shares the singleton ALLM.Keys.Store Agent.
  use ExUnit.Case, async: false

  alias ALLM.Keys.Store

  @fixture_path Path.expand("../../fixtures/sample.env", __DIR__)

  setup do
    on_exit(fn ->
      Store.clear()
      Application.delete_env(:allm, :load_dotenv)
      Application.delete_env(:allm, :dotenv_path)
    end)

    :ok
  end

  describe "application start" do
    test "ALLM.Keys.Store is registered under its module name after :allm starts" do
      {:ok, _started} = Application.ensure_all_started(:allm)
      assert is_pid(Process.whereis(Store))
    end
  end

  describe "put/2 + get/1 + delete/1" do
    test "put/2 followed by get/1 returns the stored string" do
      :ok = Store.put(:my_test_provider, "secret-1")
      assert Store.get(:my_test_provider) == "secret-1"
    end

    test "get/1 returns nil when nothing is stored" do
      assert Store.get(:unknown_provider_xyz) == nil
    end

    test "delete/1 removes a stored key" do
      :ok = Store.put(:my_test_provider, "secret-2")
      assert Store.get(:my_test_provider) == "secret-2"
      :ok = Store.delete(:my_test_provider)
      assert Store.get(:my_test_provider) == nil
    end

    test "put/2 last-write-wins under concurrent writes" do
      tasks =
        for i <- 1..100 do
          Task.async(fn -> Store.put(:my_test_provider, "v-#{i}") end)
        end

      Enum.each(tasks, &Task.await/1)

      value = Store.get(:my_test_provider)
      assert is_binary(value)
      assert String.starts_with?(value, "v-")
    end
  end

  describe "clear/0" do
    test "removes all runtime keys" do
      :ok = Store.put(:p1, "k1")
      :ok = Store.put(:p2, "k2")
      :ok = Store.clear()
      assert Store.get(:p1) == nil
      assert Store.get(:p2) == nil
    end

    test "resets the dotenv cache to :unloaded" do
      Application.put_env(:allm, :load_dotenv, true)
      Application.put_env(:allm, :dotenv_path, @fixture_path)

      # Prime the cache.
      assert Store.dotenv_lookup("OPENAI_API_KEY") == "sk-test"

      :ok = Store.clear()

      # After clear, lookups either re-load (if load_dotenv still true) or
      # return nil. We disable load_dotenv to prove the cache was dropped:
      # the previously cached value must not be returned.
      Application.put_env(:allm, :load_dotenv, false)
      assert Store.dotenv_lookup("OPENAI_API_KEY") == nil
    end
  end

  describe "dotenv_lookup/1" do
    test "triggers Dotenv.load/1 on first call when load_dotenv: true, caches subsequent calls" do
      Application.put_env(:allm, :load_dotenv, true)
      Application.put_env(:allm, :dotenv_path, @fixture_path)

      assert Store.dotenv_lookup("OPENAI_API_KEY") == "sk-test"
      # Second call hits the cached map — we don't have a way to probe the
      # Agent's internal state without reaching in, so instead we move the
      # file and confirm the value survives.
      Application.put_env(:allm, :dotenv_path, "/nonexistent/path.env")
      assert Store.dotenv_lookup("OPENAI_API_KEY") == "sk-test"
    end

    test "returns nil when load_dotenv is falsy, regardless of file contents" do
      Application.put_env(:allm, :dotenv_path, @fixture_path)
      # load_dotenv not set (default = unset, treated as false).
      assert Store.dotenv_lookup("OPENAI_API_KEY") == nil

      Application.put_env(:allm, :load_dotenv, false)
      assert Store.dotenv_lookup("OPENAI_API_KEY") == nil
    end
  end
end
