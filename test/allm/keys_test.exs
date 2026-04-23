defmodule ALLM.KeysTest do
  # async: false — tests toggle System env vars, Application env, and the
  # shared ALLM.Keys.Store Agent. Isolation is via on_exit.
  use ExUnit.Case, async: false

  alias ALLM.Error.EngineError
  alias ALLM.Keys
  alias ALLM.Keys.Store

  doctest ALLM.Keys

  @fixture_path Path.expand("../fixtures/sample.env", __DIR__)

  setup do
    # Clean slate before and after each test.
    Store.clear()
    Application.delete_env(:allm, :keys)
    Application.delete_env(:allm, :load_dotenv)
    Application.delete_env(:allm, :dotenv_path)
    System.delete_env("OPENAI_API_KEY")
    System.delete_env("MY_TEST_PROVIDER_API_KEY")

    on_exit(fn ->
      Store.clear()
      Application.delete_env(:allm, :keys)
      Application.delete_env(:allm, :load_dotenv)
      Application.delete_env(:allm, :dotenv_path)
      System.delete_env("OPENAI_API_KEY")
      System.delete_env("MY_TEST_PROVIDER_API_KEY")
    end)

    :ok
  end

  describe "put/2 + get/1" do
    test "put/2 + get/1 round-trips with source :runtime" do
      :ok = Keys.put(:my_test_provider, "rt-key")
      assert Keys.get(:my_test_provider) == {:ok, "rt-key", :runtime}
    end

    test "get/1 returns {:error, :missing} with no sources configured" do
      assert Keys.get(:my_test_provider) == {:error, :missing}
    end
  end

  describe "delete/1" do
    test "removes a runtime key" do
      :ok = Keys.put(:my_test_provider, "rt-key")
      :ok = Keys.delete(:my_test_provider)
      assert Keys.get(:my_test_provider) == {:error, :missing}
    end
  end

  describe "five-level resolution chain" do
    test "level 1: opts[:api_key] wins over everything" do
      :ok = Keys.put(:openai, "runtime-value")
      Application.put_env(:allm, :keys, %{openai: "app-value"})
      System.put_env("OPENAI_API_KEY", "env-value")

      assert Keys.get(:openai, api_key: "explicit") == {:ok, "explicit", :opts}
    end

    test "level 2: runtime store wins over app_config, env, dotenv" do
      :ok = Keys.put(:openai, "runtime-value")
      Application.put_env(:allm, :keys, %{openai: "app-value"})
      System.put_env("OPENAI_API_KEY", "env-value")

      assert Keys.get(:openai) == {:ok, "runtime-value", :runtime}
    end

    test "level 3: app_config wins over env, dotenv" do
      Application.put_env(:allm, :keys, %{openai: "app-value"})
      System.put_env("OPENAI_API_KEY", "env-value")

      assert Keys.get(:openai) == {:ok, "app-value", :app_config}
    end

    test "level 4: env wins over dotenv" do
      Application.put_env(:allm, :load_dotenv, true)
      Application.put_env(:allm, :dotenv_path, @fixture_path)
      System.put_env("OPENAI_API_KEY", "env-value")

      assert Keys.get(:openai) == {:ok, "env-value", :env}
    end

    test "level 5: dotenv is consulted only when load_dotenv: true" do
      Application.put_env(:allm, :load_dotenv, true)
      Application.put_env(:allm, :dotenv_path, @fixture_path)

      assert Keys.get(:openai) == {:ok, "sk-test", :dotenv}
    end

    test "dotenv disabled (load_dotenv unset): .env entries do NOT satisfy resolution" do
      Application.put_env(:allm, :dotenv_path, @fixture_path)
      # load_dotenv is intentionally not set.
      assert Keys.get(:openai) == {:error, :missing}
    end

    test "dotenv disabled (load_dotenv: false): .env entries do NOT satisfy resolution" do
      Application.put_env(:allm, :load_dotenv, false)
      Application.put_env(:allm, :dotenv_path, @fixture_path)

      assert Keys.get(:openai) == {:error, :missing}
    end
  end

  describe "empty-string handling" do
    test "empty string in runtime store is treated as missing" do
      :ok = Keys.put(:my_test_provider, "")
      assert Keys.get(:my_test_provider) == {:error, :missing}
    end

    test "empty string in app_config is treated as missing" do
      Application.put_env(:allm, :keys, %{my_test_provider: ""})
      assert Keys.get(:my_test_provider) == {:error, :missing}
    end

    test "empty string in env var is treated as missing" do
      System.put_env("MY_TEST_PROVIDER_API_KEY", "")
      assert Keys.get(:my_test_provider) == {:error, :missing}
    end

    test "empty string in opts[:api_key] does NOT win (falls through)" do
      :ok = Keys.put(:my_test_provider, "rt")
      assert Keys.get(:my_test_provider, api_key: "") == {:ok, "rt", :runtime}
    end
  end

  describe "env_var_for/1" do
    test "maps known providers to their documented env-var names" do
      assert Keys.env_var_for(:openai) == "OPENAI_API_KEY"
      assert Keys.env_var_for(:anthropic) == "ANTHROPIC_API_KEY"
      assert Keys.env_var_for(:google) == "GOOGLE_API_KEY"
      assert Keys.env_var_for(:cohere) == "COHERE_API_KEY"
      assert Keys.env_var_for(:mistral) == "MISTRAL_API_KEY"
      assert Keys.env_var_for(:fake) == "FAKE_API_KEY"
    end

    test "falls back to UPPERCASED_PROVIDER_API_KEY for unknown providers" do
      assert Keys.env_var_for(:some_unknown) == "SOME_UNKNOWN_API_KEY"
    end
  end

  describe "fetch!/2" do
    test "returns the string on hit" do
      :ok = Keys.put(:my_test_provider, "ok-key")
      assert Keys.fetch!(:my_test_provider) == "ok-key"
    end

    test "raises EngineError with :missing_key on miss" do
      err =
        assert_raise EngineError, fn ->
          Keys.fetch!(:my_test_provider)
        end

      assert err.reason == :missing_key
      assert err.provider == :my_test_provider
      assert is_binary(Exception.message(err))
      assert Exception.message(err) != ""
    end

    test "metadata.checked_sources omits :dotenv when load_dotenv is off" do
      err =
        assert_raise EngineError, fn ->
          Keys.fetch!(:my_test_provider)
        end

      sources = err.metadata.checked_sources
      assert :opts in sources
      assert :runtime in sources
      assert :app_config in sources
      assert :env in sources
      refute :dotenv in sources
    end

    test "metadata.checked_sources includes :dotenv when load_dotenv: true" do
      Application.put_env(:allm, :load_dotenv, true)
      Application.put_env(:allm, :dotenv_path, "/nonexistent.env")

      err =
        assert_raise EngineError, fn ->
          Keys.fetch!(:my_test_provider)
        end

      assert :dotenv in err.metadata.checked_sources
    end

    test "honors opts[:api_key] override (never misses when opts has key)" do
      assert Keys.fetch!(:my_test_provider, api_key: "explicit") == "explicit"
    end
  end
end
