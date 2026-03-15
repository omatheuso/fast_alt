defmodule FastAlt.HTMLScanner do
  @moduledoc """
  Parses an HTML binary and extracts every `<img>` entry with its `src` and `alt` values.

  - `alt: nil`  — the `alt` attribute is entirely absent from the tag
  - `alt: ""`   — the `alt` attribute is present but blank
  - `alt: text` — the `alt` attribute has a non-empty value

  Uses LazyHTML (Lexbor NIF) internally, which correctly handles malformed HTML
  as a browser would.
  """

  @type img_entry :: %{src: String.t(), alt: String.t() | nil}

  @doc """
  Returns a list of `%{src, alt}` maps for every `<img>` found in `html_binary`.

  Images without a `src` attribute are skipped.
  """
  @spec scan_html(html_binary :: String.t()) :: [img_entry()]
  def scan_html(html_binary) do
    html_binary
    |> LazyHTML.from_document()
    |> LazyHTML.query("img")
    |> LazyHTML.attributes()
    |> Enum.reduce([], fn attrs, acc ->
      src = find_attr(attrs, "src")

      if src do
        alt = find_attr(attrs, "alt")
        [%{src: src, alt: alt} | acc]
      else
        acc
      end
    end)
    |> Enum.reverse()
  end

  defp find_attr(attrs, name) do
    case List.keyfind(attrs, name, 0) do
      {_name, value} -> value
      nil -> nil
    end
  end
end
