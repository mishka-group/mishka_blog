# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.XmlTest do
  @moduledoc """
  The XML reader the feed tests use gives back what a feed reader sees: prefixed elements and
  attributes by their prefix, a default namespace by `local-name()`, entities decoded, split CDATA
  sections as one text, and a document that uses an undeclared prefix refused.
  """
  use ExUnit.Case, async: true

  alias MishkaBlog.Test.Xml

  @rss """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
      <atom:link href="https://example.test/feed" rel="self"/>
      <item><title>A &amp; &lt;b&gt;B&lt;/b&gt;</title><dc:creator>Mona</dc:creator><content:encoded><![CDATA[<p>a ]]]]><![CDATA[> b</p>]]></content:encoded></item>
      <item><title>سلام 😀</title></item>
    </channel>
  </rss>
  """

  test "reads prefixed elements and attributes by the prefix the document writes" do
    assert Xml.text(@rss, "//channel/atom:link/@href") == "https://example.test/feed"
    assert Xml.text(@rss, "//item/dc:creator/text()") == "Mona"
    assert Xml.text(@rss, "//item/content:encoded/text()") == "<p>a ]]> b</p>"
  end

  test "decodes entities and characters past the Basic Multilingual Plane, one string per node" do
    assert Xml.texts(@rss, "//item/title/text()") == ["A & <b>B</b>", "سلام 😀"]
    assert Xml.text(@rss, "//item[1]/title/text()") == "A & <b>B</b>"
  end

  test "reaches a default namespace with local-name()" do
    atom = ~s(<feed xmlns="http://www.w3.org/2005/Atom"><entry><title>Hi</title></entry></feed>)

    assert Xml.text(atom, "//*[local-name()='entry']/*[local-name()='title']/text()") == "Hi"
  end

  test "matches nothing as an empty string and no nodes" do
    assert Xml.text(@rss, "//item/missing/text()") == ""
    assert Xml.nodes(@rss, "//item/media:thumbnail") == []
    assert [_, _] = Xml.nodes(@rss, "//item")
  end

  test "refuses a document that uses a prefix it never declared" do
    assert catch_exit(Xml.nodes("<rss><content:encoded>x</content:encoded></rss>", "//rss"))
  end
end
