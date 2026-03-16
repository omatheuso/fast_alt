defmodule FastAlt.AltPatcher do
  @moduledoc """
  Injects or replaces `alt` attributes in an HTML file in-place.

  Given a list of `{src, generated_alt}` pairs, finds every matching `<img>`
  tag by its `src` and writes the `alt` attribute back to the file.

  Uses a LazyHTML round-trip:
    read file → parse → tree → walk → inject alt → serialize → write

  Known trade-off: LazyHTML normalizes HTML on round-trip (whitespace,
  self-closing tags). This is acceptable for compiled/generated build output
  but not ideal for hand-crafted templates.
  """

  @doc """
  Patches `html_path` in-place, applying each `{src, alt}` pair in `patches`.

  Images whose `src` does not appear in `patches` are left untouched.
  If a matching `<img>` already has an `alt` attribute, it is replaced.
  """
  @spec patch_file(
          html_path :: String.t(),
          patches :: [{src :: String.t(), alt :: String.t()}]
        ) :: :ok | {:error, term()}
  def patch_file(_html_path, []), do: :ok

  def patch_file(html_path, patches) do
    patch_map = Map.new(patches)

    with {:ok, html_binary} <- File.read(html_path) do
      patched =
        html_binary
        |> LazyHTML.from_document()
        |> LazyHTML.to_tree()
        |> LazyHTML.Tree.postwalk(&patch_node(&1, patch_map))
        |> LazyHTML.from_tree()
        |> LazyHTML.to_html()

      File.write(html_path, patched)
    end
  end

  defp patch_node({"img", attrs, children}, patch_map) do
    case List.keyfind(attrs, "src", 0) do
      {"src", src} ->
        case Map.fetch(patch_map, src) do
          {:ok, alt} ->
            new_attrs =
              attrs
              |> List.keydelete("alt", 0)
              |> List.keystore("alt", 0, {"alt", alt})

            {"img", new_attrs, children}

          :error ->
            {"img", attrs, children}
        end

      nil ->
        {"img", attrs, children}
    end
  end

  defp patch_node(node, _patch_map), do: node
end
