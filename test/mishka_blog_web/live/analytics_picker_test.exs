defmodule MishkaBlogWeb.Live.AnalyticsPickerTest do
  @moduledoc """
  The analytics filters draw gervaz's search select from `picker_assigns/3` outside a component,
  so the assigns must say every part changed: a live page diffs the select against the one it drew
  last, and a part read as unchanged keeps the shut select's attributes on the open one.
  """
  use ExUnit.Case, async: true

  alias MishkaBlogWeb.Live.Admin.Dashboard.Analytics.Index

  defp tracked(%Phoenix.LiveView.Rendered{static: static, dynamic: dynamic}) do
    parts = Enum.map(dynamic.(true), &tracked/1)

    static
    |> Enum.zip(parts ++ [""])
    |> Enum.map_join(fn {text, part} -> text <> part end)
  end

  defp tracked(nil), do: ""
  defp tracked(text) when is_binary(text), do: text
  defp tracked(iodata) when is_list(iodata), do: IO.iodata_to_binary(iodata)
  defp tracked(other), do: other |> Phoenix.HTML.Safe.to_iodata() |> IO.iodata_to_binary()

  test "an open filter is drawn open on a live page's diff" do
    picker = %{
      options: [{"News", "1"}],
      more?: false,
      loading?: false,
      open?: true,
      search: "",
      picked: nil
    }

    html =
      "category"
      |> Index.picker_assigns(picker, nil)
      |> MishkaGervaz.UIAdapters.Tailwind.search_select()
      |> tracked()

    assert html =~ ~s(aria-expanded="true")
    assert html =~ ~s(phx-click-away="relation_close_dropdown")
  end
end
