defmodule FastAlt.FileScanner do
  @moduledoc """
  Recursively walks a directory and collects all `.html` and `.htm` file paths.
  Returns a sorted list of absolute paths. No dependencies beyond the standard library.
  """

  @html_extensions [".html", ".htm"]

  @doc """
  Recursively finds all HTML files under `root`.

  Returns a sorted list of absolute paths. Non-existent or non-directory `root`
  returns an empty list.
  """
  @spec find_html_files(root :: String.t()) :: [String.t()]
  def find_html_files(root) do
    root
    |> Path.expand()
    |> collect([])
    |> Enum.sort()
  end

  defp collect(path, acc) do
    cond do
      File.dir?(path) ->
        path
        |> File.ls!()
        |> Enum.reduce(acc, fn entry, acc ->
          collect(Path.join(path, entry), acc)
        end)

      File.regular?(path) and Path.extname(path) in @html_extensions ->
        [path | acc]

      true ->
        acc
    end
  end
end
