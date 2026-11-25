# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Feeds.RendererTest do
  @moduledoc """
  A feed written in each format parses back to what went in: HTML survives in CDATA whatever it
  holds, a `]]>` included, every text keeps only the characters XML 1.0 allows and only UTF-8, markup in a
  title is escaped, and an Atom entry with no author names the feed.
  """
  use ExUnit.Case, async: true

  alias MishkaBlog.Feeds.Renderer
  alias MishkaBlog.Test.Xml

  defp feed(item) do
    %{
      title: "Feed Site",
      description: "Feed Site",
      language: "en",
      link: "https://example.test/blog",
      self_url: "https://example.test/feed",
      updated_at: ~U[2026-11-01 10:00:00Z],
      items: [
        Map.merge(
          %{
            url: "https://example.test/blog/hello",
            title: "Hello",
            summary: "About it",
            content_html: "<p>Body</p>",
            published_at: ~U[2026-11-01 10:00:00Z],
            updated_at: ~U[2026-11-01 10:00:00Z],
            authors: ["Mona"],
            categories: ["Elixir"],
            image_url: nil,
            language: "en"
          },
          item
        )
      ]
    }
  end

  test "keeps HTML in CDATA, a ]]> included, and escapes a title" do
    rss = Renderer.render(:rss, feed(%{title: "A & <b>B</b>", content_html: "<p>a ]]> b</p>"}))

    assert rss =~ "<![CDATA["
    assert Xml.text(rss, "//item/title/text()") == "A & <b>B</b>"
    assert Xml.text(rss, "//item/content:encoded/text()") == "<p>a ]]> b</p>"
  end

  test "takes the characters XML forbids out of every text" do
    item = %{title: "Bad\u0001 title", summary: "x\u0000y", content_html: "<p>a\u000Bb￾c</p>"}
    rss = Renderer.render(:rss, feed(item))

    assert Xml.text(rss, "//item/title/text()") == "Bad title"
    assert Xml.text(rss, "//item/description/text()") == "xy"
    assert Xml.text(rss, "//item/content:encoded/text()") == "<p>abc</p>"

    assert [%{"title" => "Bad title"}] =
             :json |> Renderer.render(feed(item)) |> Jason.decode!() |> Map.fetch!("items")
  end

  test "keeps every character XML allows, beyond the Basic Multilingual Plane included" do
    text = "tab\there\nسلام 😀 \u00A0\u{FFFD}"

    for format <- [:rss, :atom] do
      doc = Renderer.render(format, feed(%{title: text}))
      path = if format == :rss, do: "//item/title/text()", else: "//entry/title/text()"
      assert Xml.text(doc, path) == text
    end
  end

  test "drops bytes that are not UTF-8 and still writes every format" do
    item = %{title: "a" <> <<0xFF, 0xC3>> <> "b", content_html: <<"<p>x", 0x80, "y</p>">>}

    assert %{"items" => [%{"title" => "ab"}]} =
             :json |> Renderer.render(feed(item)) |> Jason.decode!()

    assert Xml.text(Renderer.render(:atom, feed(item)), "//entry/title/text()") == "ab"

    rss = Renderer.render(:rss, feed(item))
    assert Xml.text(rss, "//item/title/text()") == "ab"
    assert Xml.text(rss, "//item/content:encoded/text()") == "<p>xy</p>"
  end

  test "an Atom entry with no author names the feed, and its content is html" do
    atom = Renderer.render(:atom, feed(%{authors: []}))

    assert Xml.text(
             atom,
             "//*[local-name()='entry']/*[local-name()='author']/*[local-name()='name']/text()"
           ) == "Feed Site"

    assert Xml.text(atom, "//*[local-name()='entry']/*[local-name()='content']/@type") == "html"

    assert Xml.text(atom, "//*[local-name()='entry']/*[local-name()='category']/@term") ==
             "Elixir"
  end
end
