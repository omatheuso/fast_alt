defmodule FastAlt.ImageResolver do
  @moduledoc """
  Resolves an `<img src>` value to an absolute path on disk.

  Returns `{:ok, absolute_path}` when the image exists locally, or
  `{:skip, reason}` when it should be skipped.

  Skipped cases:
  - `data:` URIs (inline base64 images)
  - External URLs: `http://`, `https://`, or protocol-relative `//`
  - Relative/absolute paths that don't exist on disk
  """

  @external_prefixes ["http://", "https://", "//"]

  @doc """
  Resolves `src` relative to the directory of `html_file_path`.

  `html_file_path` must be an absolute path.
  """
  @spec resolve(src :: String.t(), html_file_path :: String.t()) ::
          {:ok, String.t()} | {:skip, String.t()}
  def resolve("data:" <> _, _html_file_path) do
    {:skip, "data URI"}
  end

  def resolve(src, html_file_path) when is_binary(src) do
    if Enum.any?(@external_prefixes, &String.starts_with?(src, &1)) do
      {:skip, "external URL"}
    else
      resolve_local(src, html_file_path)
    end
  end

  defp resolve_local(src, html_file_path) do
    abs_path =
      src
      |> Path.expand(Path.dirname(html_file_path))

    if File.exists?(abs_path) do
      {:ok, abs_path}
    else
      {:skip, "file not found: #{src}"}
    end
  end
end
