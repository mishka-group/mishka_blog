defmodule MishkaBlog.ContentScrubber do
  @moduledoc """
  The HTML scrubber for a post's `content`.

  It keeps everything `HtmlSanitizeEx.html5/1` allows and adds the safe parts of a
  post that html5 removes:

    * `<figure>` and `<figcaption>`, with the attribute rules of `<div>`.
    * `srcset` and `sizes` on `<img>` and `<source>`. A `srcset` is kept only when every
      candidate is a URL that passes the scheme check html5 applies to `src` (http, https,
      mailto or relative) followed by an optional `1x` or `100w` descriptor. One bad
      candidate drops the whole attribute. `sizes` is kept only when it is a plain list of
      media conditions and lengths.
    * `allowfullscreen` and `allow` on `<iframe>`. `allow` keeps only the permission tokens
      in `allowed_permissions/0`, without origin lists, and is dropped when none remain.

  Every other tag and attribute follows html5, so scripts, `on*` handlers, `javascript:`
  and `data:` URLs and the rest stay removed. `<picture>` is not allowed by html5, so only
  its children stay.

  `GuardedStruct` reaches it through the `sanitize_derive` option, as `sanitize(blog_html)`.
  """

  use HtmlSanitizeEx, extend: :html5

  alias HtmlSanitizeEx.Scrubber.HTML5
  alias HtmlSanitizeEx.Scrubber.URI, as: UriScrubber

  @schemes ["http", "https", "mailto"]
  @allowed_permissions ~w(fullscreen picture-in-picture encrypted-media autoplay clipboard-write
                          accelerometer gyroscope web-share)
  @descriptor ~r/\A\d+(\.\d+)?[wx]\z/
  @sizes ~r/\A[A-Za-z0-9\s(),:.%+\-*\/]+\z/

  # Registering a tag here makes this module scrub its attributes, so the clauses below apply
  # to it instead of html5's own.
  allow_tag_with_these_attributes("figure")
  allow_tag_with_these_attributes("figcaption")
  allow_tag_with_these_attributes("img")
  allow_tag_with_these_attributes("source")
  allow_tag_with_these_attributes("iframe")

  @doc """
  Permissions an embedded player needs (fullscreen, autoplay, picture-in-picture and similar).
  Powerful ones such as camera, microphone and geolocation are never on the list.
  """
  @spec allowed_permissions() :: [String.t()]
  def allowed_permissions, do: @allowed_permissions

  @doc """
  Serves `sanitize(blog_html)` in a guardedstruct `derives` string. Any other op returns `nil`,
  which tells GuardedStruct this module does not handle it and the next sanitizer should.
  """
  @spec sanitize(term(), atom()) :: term()
  def sanitize(input, :blog_html) when is_binary(input), do: sanitize(input)
  def sanitize(input, :blog_html), do: input
  def sanitize(_input, _op), do: nil

  def scrub_attribute(tag, attribute) when tag in ["figure", "figcaption"],
    do: HTML5.scrub_attribute("div", attribute)

  def scrub_attribute(tag, {"srcset", value}) when tag in ["img", "source"],
    do: scrub_srcset(value)

  def scrub_attribute(tag, {"sizes", value}) when tag in ["img", "source"],
    do: scrub_sizes(value)

  def scrub_attribute("iframe", {"allowfullscreen", value})
      when value in ["", "allowfullscreen", "true"],
      do: {"allowfullscreen", ""}

  def scrub_attribute("iframe", {"allow", value}), do: scrub_allow(value)

  defp scrub_srcset(value) do
    candidates = value |> String.split(",") |> Enum.map(&String.trim/1)

    if candidates != [""] and Enum.all?(candidates, &safe_candidate?/1) do
      {"srcset", value}
    end
  end

  defp safe_candidate?(candidate) do
    case String.split(candidate) do
      [url] -> safe_url?(url)
      [url, descriptor] -> safe_url?(url) and descriptor =~ @descriptor
      _ -> false
    end
  end

  defp safe_url?(url),
    do: UriScrubber.scrub_attribute("img", {"srcset", url}, @schemes) != nil

  defp scrub_sizes(value) do
    if value =~ @sizes, do: {"sizes", value}
  end

  defp scrub_allow(value) do
    tokens =
      value
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.filter(&(&1 in @allowed_permissions))
      |> Enum.uniq()

    if tokens != [], do: {"allow", Enum.join(tokens, "; ")}
  end
end
