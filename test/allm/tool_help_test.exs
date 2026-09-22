defmodule ALLM.ToolHelpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ALLM.Test.Generators
  alias ALLM.{Tool, ToolCall, ToolHelp}
  alias ALLM.ToolResultEncoder.JSON, as: JSONEncoder

  doctest ToolHelp

  @usage_prefix ~s(tool_help expects {"names": ["tool_name", ...]}. Compact tools: )

  defp tool(opts) do
    Tool.new(Keyword.merge([name: "t", description: "A tool.", schema: %{}], opts))
  end

  defp fixture_tools(compact) do
    Enum.map(CompactToolsFixture.tools(), fn t ->
      Tool.new(Map.to_list(t) ++ [compact: compact])
    end)
  end

  defp fixture_tool(name, compact \\ true) do
    Enum.find(fixture_tools(compact), &(&1.name == name))
  end

  defp schema(props, required \\ nil) do
    base = %{"type" => "object", "properties" => Map.new(props, &{&1, %{"type" => "string"}})}
    if required, do: Map.put(base, "required", required), else: base
  end

  describe "CompactToolsFixture" do
    test "8 tools, 3-7 params each, every array property carries items" do
      tools = CompactToolsFixture.tools()
      assert length(tools) == 8
      assert tools |> Enum.map(& &1.name) |> Enum.uniq() |> length() == 8

      for %{schema: %{"properties" => props}} <- tools do
        assert map_size(props) in 3..7

        for {_name, %{"type" => "array"} = p} <- props do
          assert %{"type" => _} = p["items"]
        end
      end
    end
  end

  describe "summary/1" do
    test "an explicit summary wins" do
      assert ToolHelp.summary(tool(description: "Long. Text.", summary: "Short")) == "Short"
    end

    test "an empty explicit summary falls back to derivation" do
      assert ToolHelp.summary(tool(description: "Derived. More.", summary: "")) == "Derived."
    end

    test "first sentence ends at a period followed by a space" do
      assert ToolHelp.summary(tool(description: "  First one. Second one.  ")) == "First one."
    end

    test "! and ? terminate a sentence" do
      assert ToolHelp.summary(tool(description: "Wow! More.")) == "Wow!"
      assert ToolHelp.summary(tool(description: "Really? More.")) == "Really?"
    end

    test "a newline before any terminator stops the summary" do
      assert ToolHelp.summary(tool(description: "First line\nSecond line. More.")) ==
               "First line"
    end

    test "a terminator at end of string is kept" do
      assert ToolHelp.summary(tool(description: "Only sentence.")) == "Only sentence."
    end

    test "no terminator yields the whole trimmed text" do
      assert ToolHelp.summary(tool(description: "  no terminator here  ")) ==
               "no terminator here"
    end

    test "a 200-char single sentence is cut to 157 graphemes plus ..." do
      desc = String.duplicate("a", 199) <> "."
      summary = ToolHelp.summary(tool(description: desc))
      assert summary == String.duplicate("a", 157) <> "..."
      assert String.length(summary) == 160
    end

    test "exactly 160 graphemes is not truncated" do
      desc = String.duplicate("b", 160)
      assert ToolHelp.summary(tool(description: desc)) == desc
    end

    test "a period not followed by whitespace does not split" do
      assert ToolHelp.summary(tool(description: "v1.2 is great. More.")) == "v1.2 is great."
    end

    test "an empty description yields an empty string" do
      assert ToolHelp.summary(tool(description: "")) == ""
    end

    test "abbreviations split (documented limitation)" do
      assert ToolHelp.summary(tool(description: "Use e.g. this. More.")) == "Use e.g."
    end
  end

  describe "signature/1" do
    test "required names in required order, then sorted optional names" do
      t = tool(schema: schema(~w(z_opt a_opt title repo), ["title", "repo"]))
      assert ToolHelp.signature(t) == "Args: title, repo [a_opt, z_opt]"
    end

    test "no required names" do
      assert ToolHelp.signature(tool(schema: schema(~w(b a)))) == "Args: [a, b]"
    end

    test "no optional names omits the bracket group" do
      assert ToolHelp.signature(tool(schema: schema(~w(a b), ["b", "a"]))) == "Args: b, a"
    end

    test "empty properties yields Args: none" do
      assert ToolHelp.signature(tool(schema: %{"type" => "object", "properties" => %{}})) ==
               "Args: none"
    end

    test "missing properties yields nil" do
      assert ToolHelp.signature(tool(schema: %{"type" => "object"})) == nil
      assert ToolHelp.signature(tool(schema: %{})) == nil
    end

    test "non-map properties yields nil" do
      assert ToolHelp.signature(tool(schema: %{"properties" => ["a"]})) == nil
    end

    test "a required name absent from properties is dropped" do
      assert ToolHelp.signature(tool(schema: schema(~w(a b), ["ghost", "a"]))) == "Args: a [b]"
    end

    test "a non-list required is treated as no required names" do
      assert ToolHelp.signature(tool(schema: schema(~w(a), "a"))) == "Args: [a]"
    end

    test "a 40-property map built from a reversed key list lists optionals in sorted order" do
      names = for i <- 1..40, do: "p" <> String.pad_leading(Integer.to_string(i), 2, "0")
      props = names |> Enum.reverse() |> Map.new(&{&1, %{"type" => "string"}})
      t = tool(schema: %{"type" => "object", "properties" => props})

      assert ToolHelp.signature(t) == "Args: [" <> Enum.join(Enum.sort(names), ", ") <> "]"
    end
  end

  describe "stub/1" do
    test "the fixture's create_issue stub description is exact" do
      stub = ToolHelp.stub(fixture_tool("create_issue"))

      assert stub.description ==
               "Create a new issue in a repository. Args: repo, title " <>
                 "[assignees, body, labels, milestone] [compact]"
    end

    test "schema becomes a bare object, handler nil, other fields preserved" do
      t =
        tool(
          name: "x",
          schema: schema(~w(a)),
          handler: fn _ -> {:ok, 1} end,
          compact: true,
          manual: true,
          summary: "S",
          metadata: %{"k" => "v"}
        )

      stub = ToolHelp.stub(t)
      assert stub.schema == %{"type" => "object"}
      assert stub.handler == nil
      assert stub.description == "S Args: [a] [compact]"

      assert {stub.name, stub.compact, stub.manual, stub.summary, stub.metadata} ==
               {"x", true, true, "S", %{"k" => "v"}}
    end

    test "empty description and no properties yields just [compact]" do
      assert ToolHelp.stub(tool(description: "", schema: %{})).description == "[compact]"
    end
  end

  describe "compact?/1" do
    test "only compact == true counts as compact (safe direction)" do
      assert ToolHelp.compact?(tool(compact: true))
      refute ToolHelp.compact?(tool(compact: false))
      # Hand-built / JSON-hydrated badly-typed values are not compact.
      refute ToolHelp.compact?(%Tool{name: "t", description: "d", schema: %{}, compact: :yes})
      refute ToolHelp.compact?(%Tool{name: "t", description: "d", schema: %{}, compact: "yes"})
      refute ToolHelp.compact?(%Tool{name: "t", description: "d", schema: %{}, compact: nil})
    end

    test "a JSON-hydrated compact: \"yes\" tool is sent in full by project/2" do
      json =
        tool(name: "x", compact: true)
        |> Jason.encode!()
        |> String.replace(~s("compact":true), ~s("compact":"yes"))

      {:ok, hydrated} = ALLM.Serializer.from_json(json)
      assert hydrated.compact == "yes"
      assert ToolHelp.project([hydrated], nil) == [hydrated]
    end
  end

  describe "with_meta_tool/1" do
    test "no compact tool returns the input unchanged" do
      tools = [tool(name: "a"), tool(name: "b")]
      assert ToolHelp.with_meta_tool(tools) == tools
      assert ToolHelp.with_meta_tool([]) == []
    end

    test "one compact tool appends the meta-tool once" do
      tools = [tool(name: "a", compact: true), tool(name: "b")]
      assert ToolHelp.with_meta_tool(tools) == tools ++ [ToolHelp.meta_tool()]
    end

    test "idempotent on already-expanded input" do
      expanded = ToolHelp.with_meta_tool([tool(name: "a", compact: true)])
      assert ToolHelp.with_meta_tool(expanded) == expanded
    end

    test "names the same tools as project/2 (wire and execution lists agree)" do
      tools = [tool(name: "x", compact: true), tool(name: "full"), tool(name: "y", compact: true)]

      for choice <- [nil, :auto, "x"] do
        assert Enum.map(ToolHelp.project(tools, choice), & &1.name) ==
                 Enum.map(ToolHelp.with_meta_tool(tools), & &1.name),
               "choice: #{inspect(choice)}"
      end
    end
  end

  describe "project/2" do
    setup do
      a = tool(name: "a", schema: schema(~w(q), ["q"]), compact: true)
      full = tool(name: "full", schema: schema(~w(z)))
      b = tool(name: "b", schema: schema(~w(r)), compact: true)
      %{a: a, full: full, b: b, tools: [a, full, b]}
    end

    test "order preserved, non-compact untouched, compact stubbed, meta appended", ctx do
      assert ToolHelp.project(ctx.tools, nil) ==
               [ToolHelp.stub(ctx.a), ctx.full, ToolHelp.stub(ctx.b), ToolHelp.meta_tool()]
    end

    test "no compact tools is a no-op", ctx do
      assert ToolHelp.project([ctx.full], :auto) == [ctx.full]
    end

    test "a forced compact tool is sent in full; others stubbed", ctx do
      expected = [ctx.a, ctx.full, ToolHelp.stub(ctx.b), ToolHelp.meta_tool()]

      for choice <- [
            "a",
            {:tool, "a"},
            %{"type" => "tool", "name" => "a"},
            %{type: "tool", name: "a"},
            %{"type" => "function", "function" => %{"name" => "a"}},
            %{type: "function", function: %{name: "a"}},
            %{"type" => "function", "name" => "a"},
            %{type: "function", name: "a"},
            %{"mode" => "ANY", "allowedFunctionNames" => ["a"]},
            %{mode: "ANY", allowedFunctionNames: ["a"]}
          ] do
        assert ToolHelp.project(ctx.tools, choice) == expected, "choice: #{inspect(choice)}"
      end
    end

    test "non-forcing choices leave every compact tool stubbed", ctx do
      expected = ToolHelp.project(ctx.tools, nil)

      for choice <- [
            :auto,
            :none,
            :required,
            %{"type" => "auto"},
            %{"mode" => "ANY", "allowedFunctionNames" => ["a", "b"]},
            {:tool, :a},
            "unknown"
          ] do
        assert ToolHelp.project(ctx.tools, choice) == expected, "choice: #{inspect(choice)}"
      end
    end

    property "deterministic, and adds exactly one tool iff any is compact" do
      tool_gen =
        StreamData.bind(Generators.tool_gen(), fn t ->
          StreamData.map(StreamData.boolean(), &%{t | compact: &1})
        end)

      check all(
              tools <- StreamData.list_of(tool_gen, max_length: 6),
              choice <-
                StreamData.one_of([
                  StreamData.member_of([nil, :auto, :required, :none]),
                  Generators.tool_name_gen()
                ])
            ) do
        assert ToolHelp.project(tools, choice) == ToolHelp.project(tools, choice)

        # Equal-but-separately-built input: a JSON round trip rebuilds every
        # map, so this binds determinism across copies, not just re-calls.
        rebuilt = tools |> Jason.encode!() |> Jason.decode!() |> ALLM.Serializer.hydrate()
        assert ToolHelp.project(rebuilt, choice) == ToolHelp.project(tools, choice)

        extra = if Enum.any?(tools, &ToolHelp.compact?/1), do: 1, else: 0
        assert length(ToolHelp.project(tools, choice)) == length(tools) + extra
      end
    end
  end

  describe "render/2" do
    setup do
      tools = fixture_tools(true) ++ [tool(name: "plain", description: "Plain tool.")]
      %{tools: tools}
    end

    test "a known name renders the exact format; schema JSON decodes back ==", ctx do
      out = ToolHelp.render(ctx.tools, %{"names" => ["create_issue"]})
      t = fixture_tool("create_issue")

      assert ["## create_issue", desc, "Parameters (JSON Schema): " <> json] =
               String.split(out, "\n", parts: 3)

      assert desc == t.description
      assert Jason.decode!(json) == t.schema
      refute String.contains?(json, "\n")
    end

    test "a non-compact tool renders too", ctx do
      assert ToolHelp.render(ctx.tools, %{"names" => ["plain"]}) ==
               "## plain\nPlain tool.\nParameters (JSON Schema): {}"
    end

    test "multiple names in request order, deduplicated, joined by a blank line", ctx do
      out = ToolHelp.render(ctx.tools, %{"names" => ["get_issue", "plain", "get_issue"]})
      sections = String.split(out, "\n\n")
      assert length(sections) == 2
      assert Enum.map(sections, &hd(String.split(&1, "\n"))) == ["## get_issue", "## plain"]
    end

    test "an unknown name lists the compact tools, never the meta-tool", ctx do
      tools = ToolHelp.with_meta_tool(ctx.tools)
      out = ToolHelp.render(tools, %{"names" => ["nope"]})
      compact_names = CompactToolsFixture.tools() |> Enum.map_join(", ", & &1.name)
      assert out == "## nope\nUnknown tool. Compact tools: " <> compact_names
      refute String.contains?(out, "tool_help")
      refute String.contains?(out, "plain")
    end

    test "with no compact tool, the unknown-name note and usage string say (none)" do
      tools = [Tool.new(name: "a", description: "A.", schema: %{})]

      assert ToolHelp.render(tools, %{"names" => ["zz"]}) ==
               "## zz\nUnknown tool. Compact tools: (none)"

      assert ToolHelp.render(tools, %{}) == @usage_prefix <> "(none)"
    end

    test "a binary names value is wrapped", ctx do
      assert ToolHelp.render(ctx.tools, %{"names" => "plain"}) ==
               ToolHelp.render(ctx.tools, %{"names" => ["plain"]})
    end

    test "atom-keyed args are accepted", ctx do
      assert ToolHelp.render(ctx.tools, %{names: ["plain"]}) ==
               ToolHelp.render(ctx.tools, %{"names" => ["plain"]})

      assert ToolHelp.render(ctx.tools, %{names: "plain"}) ==
               ToolHelp.render(ctx.tools, %{"names" => ["plain"]})
    end

    test "malformed args yield the usage string", ctx do
      compact_names = CompactToolsFixture.tools() |> Enum.map_join(", ", & &1.name)
      usage = @usage_prefix <> compact_names

      for args <- [%{}, %{"names" => 3}, %{"names" => []}, %{"names" => ["a", 1]}, nil, "x"] do
        assert ToolHelp.render(ctx.tools, args) == usage, "args: #{inspect(args)}"
      end
    end

    test "requesting the meta-tool by name renders it" do
      out = ToolHelp.render([ToolHelp.meta_tool()], %{"names" => ["tool_help"]})
      assert String.starts_with?(out, "## tool_help\n" <> ToolHelp.meta_tool().description)
    end

    test "never raises on an unencodable schema; falls back to inspect" do
      bad = %Tool{name: "bad", description: "d", schema: %{"x" => {1, 2}}}
      out = ToolHelp.render([bad], %{"names" => ["bad"]})
      assert out == "## bad\nd\nParameters (JSON Schema): " <> inspect(bad.schema)

      bad2 = %Tool{name: "bad2", description: "d", schema: %{"x" => <<0xFF>>}}
      out2 = ToolHelp.render([bad2], %{"names" => ["bad2"]})
      assert out2 == "## bad2\nd\nParameters (JSON Schema): " <> inspect(bad2.schema)
    end
  end

  describe "answer/2" do
    test "equals render/2 on the tool call's arguments" do
      tools = ToolHelp.with_meta_tool(fixture_tools(true))
      tc = ToolCall.new(id: "c1", name: "tool_help", arguments: %{"names" => ["get_issue"]})
      assert ToolHelp.answer(tools, tc) == ToolHelp.render(tools, tc.arguments)
    end

    test "nil arguments yield the usage string" do
      tools = fixture_tools(true)
      tc = ToolCall.new(id: "c1", name: "tool_help", arguments: nil)
      assert String.starts_with?(ToolHelp.answer(tools, tc), @usage_prefix)
    end
  end

  describe "check_args/2" do
    setup do
      %{x: tool(name: "x", schema: schema(~w(a b c), ["a", "b"]), compact: true)}
    end

    test "a non-compact tool is :ok regardless of args", ctx do
      assert ToolHelp.check_args(%{ctx.x | compact: false}, %{}) == :ok
      assert ToolHelp.check_args(%{ctx.x | compact: :yes}, %{}) == :ok
    end

    test "all required present is :ok (string or atom keys)", ctx do
      assert ToolHelp.check_args(ctx.x, %{"a" => 1, "b" => 2}) == :ok
      assert ToolHelp.check_args(ctx.x, %{a: 1, b: 2}) == :ok
      assert ToolHelp.check_args(ctx.x, %{"a" => 1, b: 2}) == :ok
    end

    test "two missing: usage error in required order, ending with the tool's help", ctx do
      assert {:error, s} = ToolHelp.check_args(ctx.x, %{"c" => 1})
      assert String.starts_with?(s, "missing required argument(s): a, b\n\n")
      assert String.ends_with?(s, ToolHelp.render([ctx.x], %{"names" => ["x"]}))
    end

    test "one missing", ctx do
      assert {:error, "missing required argument(s): b\n\n" <> _} =
               ToolHelp.check_args(ctx.x, %{"a" => 1})
    end

    test "a required name with no existing atom counts as absent" do
      name = "zz_no_such_atom_#{System.unique_integer([:positive])}"
      t = tool(name: "y", schema: schema([name], [name]), compact: true)
      assert {:error, _} = ToolHelp.check_args(t, %{})
    end

    test "no required key is :ok" do
      t = tool(name: "y", schema: schema(~w(a)), compact: true)
      assert ToolHelp.check_args(t, %{}) == :ok
    end

    test "the usage text survives the default JSON encoder as a plain string", ctx do
      {:error, s} = ToolHelp.check_args(ctx.x, %{})

      assert JSONEncoder.encode({:error, s}) |> Jason.decode!() == %{
               "error" => s
             }
    end
  end

  describe "robustness" do
    test "meta_tool?/1 never raises on metadata: nil or non-map metadata" do
      refute ToolHelp.meta_tool?(%Tool{name: "t", description: "d", schema: %{}, metadata: nil})
      refute ToolHelp.meta_tool?(%Tool{name: "t", description: "d", schema: %{}, metadata: []})
    end

    test "check_args/2 never raises on non-map args, non-map schema, non-list required" do
      compact = fn schema -> %Tool{name: "t", description: "d", schema: schema, compact: true} end

      assert {:error, "missing required argument(s): a" <> _} =
               ToolHelp.check_args(compact.(schema(~w(a), ["a"])), nil)

      assert {:error, _} = ToolHelp.check_args(compact.(schema(~w(a), ["a"])), ["a"])
      assert ToolHelp.check_args(compact.(nil), %{}) == :ok
      assert ToolHelp.check_args(compact.("schema"), %{}) == :ok
      assert ToolHelp.check_args(compact.(%{"required" => "a"}), %{}) == :ok
      assert ToolHelp.check_args(compact.(%{"required" => [1, :a, nil]}), %{}) == :ok

      assert ToolHelp.check_args(
               %Tool{name: "t", description: "d", schema: nil, compact: true, metadata: nil},
               nil
             ) == :ok
    end

    test "project/2 and render/2 tolerate a non-map schema" do
      t = %Tool{name: "t", description: "d", schema: nil, compact: true}
      assert [%Tool{description: "d [compact]"}, _meta] = ToolHelp.project([t], nil)
      assert ToolHelp.render([t], %{"names" => ["t"]}) == "## t\nd\nParameters (JSON Schema): null"
    end
  end

  describe "meta_tool/0" do
    test "has the exact contract shape" do
      assert ToolHelp.meta_tool() == %Tool{
               name: "tool_help",
               description:
                 "Tools whose description ends in [compact] are summarised. Call tool_help " <>
                   "with their names to get each one's full description and JSON parameter " <>
                   "schema before calling it, unless the Args hint is enough.",
               schema: %{
                 "type" => "object",
                 "properties" => %{
                   "names" => %{"type" => "array", "items" => %{"type" => "string"}}
                 },
                 "required" => ["names"]
               },
               handler: nil,
               manual: false,
               compact: false,
               summary: nil,
               metadata: %{"allm_builtin" => "tool_help"}
             }
    end

    test "passes Validate.tool/1" do
      assert ALLM.Validate.tool(ToolHelp.meta_tool()) == :ok
    end

    test "meta_tool?/1 is true for it and false for a user tool named tool_help" do
      assert ToolHelp.meta_tool?(ToolHelp.meta_tool())
      refute ToolHelp.meta_tool?(tool(name: "tool_help"))
    end

    test "ETF round-trip is equal (no funs)" do
      meta = ToolHelp.meta_tool()
      assert meta |> :erlang.term_to_binary() |> :erlang.binary_to_term() == meta
    end

    test "after a JSON round-trip it is still the meta-tool and with_meta_tool/1 stays idempotent" do
      list = ToolHelp.with_meta_tool([tool(name: "a", compact: true)])
      hydrated = list |> Jason.encode!() |> Jason.decode!() |> ALLM.Serializer.hydrate()

      assert hydrated == list
      assert ToolHelp.meta_tool?(List.last(hydrated))
      assert ToolHelp.with_meta_tool(hydrated) == hydrated
    end
  end
end
