# examples/fixtures/compact_tools.exs
#
# An 8-tool GitHub-style fixture as plain data, used to measure and exercise
# compact tools (`ALLM.Tool` `compact: true`, projected by `ALLM.ToolHelp`).
#
# Plain maps, not `%ALLM.Tool{}` structs, so both example scripts
# (`Code.require_file/1` from `mix run`) and the test suite (loaded once from
# `test/test_helper.exs`) can build tools with their own handlers:
#
#     CompactToolsFixture.tools()
#     |> Enum.map(fn t -> ALLM.Tool.new(Map.to_list(t) ++ [compact: true]) end)
#
# Every `array` property carries `items` (Gemini rejects an array schema
# without it).

defmodule CompactToolsFixture do
  @moduledoc false

  @spec tools() :: [%{name: String.t(), description: String.t(), schema: map()}]
  def tools do
    [
      %{
        name: "create_issue",
        description:
          "Create a new issue in a repository. Use this when the user reports a bug, " <>
            "requests a feature, or asks to track a task. The issue is opened in the " <>
            "given repository and its number and URL are returned.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Repository as owner/name."},
            "title" => %{"type" => "string", "description" => "Short issue title."},
            "body" => %{"type" => "string", "description" => "Markdown issue body."},
            "labels" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Label names to apply, e.g. bug or enhancement."
            },
            "assignees" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "GitHub usernames to assign."
            },
            "milestone" => %{
              "type" => "integer",
              "description" => "Milestone number to attach the issue to."
            }
          },
          "required" => ["repo", "title"]
        }
      },
      %{
        name: "list_issues",
        description:
          "List issues in a repository. Results are filtered by state and labels and " <>
            "sorted by the chosen field, newest first unless a direction is given.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Repository as owner/name."},
            "state" => %{
              "type" => "string",
              "enum" => ["open", "closed", "all"],
              "description" => "Issue state filter. Defaults to open."
            },
            "labels" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "Only issues carrying all of these labels."
            },
            "sort" => %{
              "type" => "string",
              "enum" => ["created", "updated", "comments"],
              "description" => "Sort field."
            },
            "per_page" => %{
              "type" => "integer",
              "description" => "Page size, 1 to 100. Defaults to 30."
            }
          },
          "required" => ["repo"]
        }
      },
      %{
        name: "get_issue",
        description:
          "Fetch a single issue by number. Returns its title, body, state, labels, " <>
            "assignees and, optionally, its comment thread.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Repository as owner/name."},
            "number" => %{"type" => "integer", "description" => "Issue number."},
            "include_comments" => %{
              "type" => "boolean",
              "description" => "Also return the issue's comments."
            }
          },
          "required" => ["repo", "number"]
        }
      },
      %{
        name: "comment_on_issue",
        description:
          "Add a comment to an existing issue or pull request. The comment body is " <>
            "Markdown and is posted as the authenticated user.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Repository as owner/name."},
            "number" => %{
              "type" => "integer",
              "description" => "Issue or pull request number."
            },
            "body" => %{"type" => "string", "description" => "Markdown comment body."}
          },
          "required" => ["repo", "number", "body"]
        }
      },
      %{
        name: "create_pull_request",
        description:
          "Open a pull request from one branch into another. Use draft mode when the " <>
            "work is not ready for review yet.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Repository as owner/name."},
            "title" => %{"type" => "string", "description" => "Pull request title."},
            "head" => %{"type" => "string", "description" => "Branch containing the changes."},
            "base" => %{"type" => "string", "description" => "Branch to merge into."},
            "body" => %{"type" => "string", "description" => "Markdown description."},
            "draft" => %{"type" => "boolean", "description" => "Open as a draft."},
            "reviewers" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" => "GitHub usernames to request reviews from."
            }
          },
          "required" => ["repo", "title", "head", "base"]
        }
      },
      %{
        name: "merge_pull_request",
        description:
          "Merge an open pull request. Fails if the pull request has conflicts or " <>
            "required checks have not passed.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Repository as owner/name."},
            "number" => %{"type" => "integer", "description" => "Pull request number."},
            "merge_method" => %{
              "type" => "string",
              "enum" => ["merge", "squash", "rebase"],
              "description" => "How to merge. Defaults to merge."
            },
            "commit_title" => %{
              "type" => "string",
              "description" => "Title for the merge commit."
            }
          },
          "required" => ["repo", "number"]
        }
      },
      %{
        name: "search_code",
        description:
          "Search code across repositories using GitHub code-search syntax. Returns " <>
            "matching file paths with a short excerpt around each match.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string", "description" => "Search query."},
            "repo" => %{
              "type" => "string",
              "description" => "Limit the search to one repository (owner/name)."
            },
            "language" => %{"type" => "string", "description" => "Limit to a language."},
            "per_page" => %{
              "type" => "integer",
              "description" => "Page size, 1 to 100. Defaults to 30."
            }
          },
          "required" => ["query"]
        }
      },
      %{
        name: "get_file_contents",
        description:
          "Read a file from a repository at a given ref. Returns the decoded text " <>
            "content, or a directory listing when the path is a directory.",
        schema: %{
          "type" => "object",
          "properties" => %{
            "repo" => %{"type" => "string", "description" => "Repository as owner/name."},
            "path" => %{"type" => "string", "description" => "File or directory path."},
            "ref" => %{
              "type" => "string",
              "description" => "Branch, tag or commit SHA. Defaults to the default branch."
            }
          },
          "required" => ["repo", "path"]
        }
      }
    ]
  end
end
