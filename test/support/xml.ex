# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.Xml do
  @moduledoc """
  Reads an XML document in a test with OTP's own `:xmerl_scan` and `:xmerl_xpath`, so the suite
  needs no XML package.

  The document is parsed namespace-conformant: a prefix the document uses without declaring it
  (`content:` with no `xmlns:content`) fails the parse, as it fails in a reader. A path names a
  prefixed element or attribute by the prefix the document writes (`//item/content:encoded`,
  `//channel/atom:link/@href`), and reaches an element in a default namespace, as Atom's are, with
  `local-name()`. Entities come back decoded and adjacent CDATA sections as one text.

      Xml.text(rss, "//item/title/text()")
      #=> "A & <b>B</b>"

      Xml.texts(rss, "//item/title/text()")
      #=> ["New", "Old"]
  """

  require Record

  for kind <- [:xmlText, :xmlAttribute, :xmlComment, :xmlPI, :xmlObj] do
    Record.defrecordp(kind, Record.extract(kind, from_lib: "xmerl/include/xmerl.hrl"))
  end

  @doc "Every node the path matches, as the strings `texts/2` gives, joined into one."
  @spec text(String.t(), String.t()) :: String.t()
  def text(xml, path), do: xml |> texts(path) |> Enum.join()

  @doc """
  The value of each node the path matches, one string per node: a text node's text, an
  attribute's value.
  """
  @spec texts(String.t(), String.t()) :: [String.t()]
  def texts(xml, path), do: xml |> nodes(path) |> Enum.map(&value/1)

  @doc "The xmerl records the path matches in the document, `[]` when it matches nothing."
  @spec nodes(String.t(), String.t()) :: [tuple()]
  def nodes(xml, path) when is_binary(xml) and is_binary(path) do
    {document, _rest} =
      xml
      |> :erlang.binary_to_list()
      |> :xmerl_scan.string(namespace_conformant: true, quiet: true)

    path
    |> String.to_charlist()
    |> :xmerl_xpath.string(document)
    |> List.wrap()
  end

  defp value(xmlText(value: value)), do: to_string(value)
  defp value(xmlAttribute(value: value)), do: to_string(value)
  defp value(xmlComment(value: value)), do: to_string(value)
  defp value(xmlPI(value: value)), do: to_string(value)
  defp value(xmlObj(value: value)), do: to_string(value)
end
