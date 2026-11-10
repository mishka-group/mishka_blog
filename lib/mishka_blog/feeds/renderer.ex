# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Feeds.Renderer do
  @moduledoc """
  Writes a feed as RSS 2.0, Atom 1.0 or JSON Feed 1.1 (`render/2`), from the one map
  `MishkaBlog.Resources.Actions.Feed` builds:

      %{
        title: "Blog", description: "Posts", language: "en",
        link: "https://example.com/blog", self_url: "https://example.com/feed",
        updated_at: ~U[2026-11-09 10:00:00Z],
        items: [%{url:, title:, summary:, content_html:, published_at:, updated_at:,
                  authors: [], categories: [], image_url:, language:}]
      }

  The XML is written by `XmlBuilder`: text and attributes are escaped by it, and an item's HTML goes
  in a CDATA section (RSS `content:encoded`, Atom `<content type="html">`) in which a `]]>` is split
  across two sections. The characters XML 1.0 forbids (control characters other than tab, line feed
  and carriage return, and U+FFFE and U+FFFF) are taken out of every text before it is written
  (`clean/1`), so no content can make a feed a reader refuses to parse. JSON Feed is written with
  `Jason`.

  The RSS `link` and `guid` of an item are its address (`isPermaLink="true"`), an Atom entry with no
  author names the feed's title as its author, as the standard requires one, and dates are RFC 822
  in RSS and RFC 3339 in Atom and JSON Feed.
  """

  @generator "Mishka CMS"
  @invalid ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x{FFFE}\x{FFFF}]/u

  @typedoc "The feed formats."
  @type format :: :rss | :atom | :json

  @doc "The formats a feed is written in."
  @spec formats() :: [format()]
  def formats, do: [:rss, :atom, :json]

  @doc "The `content-type` a feed in `format` is sent with."
  @spec content_type(format()) :: String.t()
  def content_type(:rss), do: "application/rss+xml"
  def content_type(:atom), do: "application/atom+xml"
  def content_type(:json), do: "application/feed+json"

  @doc """
  The characters XML 1.0 forbids taken out of `text`; anything that is not a binary is returned as
  it is.
  """
  @spec clean(term()) :: term()
  def clean(text) when is_binary(text), do: String.replace(text, @invalid, "")
  def clean(other), do: other

  @doc "`feed` written in `format`, as one binary."
  @spec render(format(), map()) :: binary()
  def render(:rss, feed), do: feed |> clean_feed() |> rss() |> xml()
  def render(:atom, feed), do: feed |> clean_feed() |> atom() |> xml()
  def render(:json, feed), do: feed |> clean_feed() |> json() |> Jason.encode!()

  defp clean_feed(%{items: items} = feed),
    do: feed |> clean_map() |> Map.put(:items, Enum.map(items, &clean_map/1))

  defp clean_map(map), do: Map.new(map, fn {key, value} -> {key, clean_value(value)} end)

  defp clean_value(list) when is_list(list), do: Enum.map(list, &clean_value/1)
  defp clean_value(value), do: clean(value)

  defp xml(tree), do: tree |> XmlBuilder.document() |> XmlBuilder.generate(format: :none)

  defp rss(feed) do
    {:rss,
     %{
       version: "2.0",
       "xmlns:atom": "http://www.w3.org/2005/Atom",
       "xmlns:content": "http://purl.org/rss/1.0/modules/content/",
       "xmlns:dc": "http://purl.org/dc/elements/1.1/",
       "xmlns:media": "http://search.yahoo.com/mrss/"
     },
     [
       {:channel, nil,
        [
          {:title, nil, feed.title},
          {:link, nil, feed.link},
          {:description, nil, feed.description},
          {:language, nil, feed.language},
          {:lastBuildDate, nil, rfc822(feed.updated_at)},
          {:generator, nil, @generator},
          {:"atom:link", %{href: feed.self_url, rel: "self", type: content_type(:rss)}, nil}
          | Enum.map(feed.items, &rss_item/1)
        ]}
     ]}
  end

  defp rss_item(item) do
    {:item, nil,
     [
       {:title, nil, item.title},
       {:link, nil, item.url},
       {:guid, %{isPermaLink: "true"}, item.url},
       {:pubDate, nil, rfc822(item.published_at)},
       {:description, nil, item.summary || ""}
     ] ++
       Enum.map(item.authors, &{:"dc:creator", nil, &1}) ++
       Enum.map(item.categories, &{:category, nil, &1}) ++
       enclosure(item) ++
       content(:"content:encoded", item)}
  end

  defp enclosure(%{image_url: nil}), do: []

  defp enclosure(%{image_url: url}),
    do: [{:"media:thumbnail", %{url: url}, nil}]

  defp content(name, %{content_html: html}) when is_binary(html) and html != "",
    do: [{name, nil, {:cdata, html}}]

  defp content(_name, _item), do: []

  defp atom(feed) do
    {:feed, %{xmlns: "http://www.w3.org/2005/Atom", "xml:lang": feed.language},
     [
       {:id, nil, feed.self_url},
       {:title, nil, feed.title},
       {:subtitle, nil, feed.description},
       {:updated, nil, DateTime.to_iso8601(feed.updated_at)},
       {:link, %{rel: "self", type: content_type(:atom), href: feed.self_url}, nil},
       {:link, %{rel: "alternate", type: "text/html", href: feed.link}, nil},
       {:generator, nil, @generator}
       | Enum.map(feed.items, &atom_entry(&1, feed))
     ]}
  end

  defp atom_entry(item, feed) do
    {:entry, language_attr(item.language),
     [
       {:id, nil, item.url},
       {:title, nil, item.title},
       {:link, %{rel: "alternate", type: "text/html", href: item.url}, nil},
       {:published, nil, DateTime.to_iso8601(item.published_at)},
       {:updated, nil, DateTime.to_iso8601(item.updated_at)},
       {:summary, %{type: "text"}, item.summary || ""}
     ] ++
       Enum.map(authors(item, feed), &{:author, nil, [{:name, nil, &1}]}) ++
       Enum.map(item.categories, &{:category, %{term: &1, label: &1}, nil}) ++
       atom_content(item)}
  end

  defp language_attr(language) when is_binary(language), do: %{"xml:lang": language}
  defp language_attr(_language), do: nil

  defp authors(%{authors: []}, feed), do: [feed.title]
  defp authors(%{authors: authors}, _feed), do: authors

  defp atom_content(%{content_html: html}) when is_binary(html) and html != "",
    do: [{:content, %{type: "html"}, {:cdata, html}}]

  defp atom_content(_item), do: []

  defp json(feed) do
    %{
      version: "https://jsonfeed.org/version/1.1",
      title: feed.title,
      home_page_url: feed.link,
      feed_url: feed.self_url,
      description: feed.description,
      language: feed.language,
      items: Enum.map(feed.items, &json_item/1)
    }
  end

  defp json_item(item) do
    %{
      id: item.url,
      url: item.url,
      title: item.title,
      summary: item.summary,
      content_html: item.content_html,
      image: item.image_url,
      language: item.language,
      date_published: DateTime.to_iso8601(item.published_at),
      date_modified: DateTime.to_iso8601(item.updated_at),
      authors: Enum.map(item.authors, &%{name: &1}),
      tags: item.categories
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, []] end)
    |> Map.new()
  end

  defp rfc822(%DateTime{} = date),
    do:
      date |> DateTime.shift_zone!("Etc/UTC") |> Calendar.strftime("%a, %d %b %Y %H:%M:%S +0000")
end
