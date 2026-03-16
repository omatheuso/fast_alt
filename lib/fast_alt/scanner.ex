defmodule FastAlt.Scanner do
  @moduledoc """
  Top-level orchestrator. Wires together `FileScanner`, `HTMLScanner`,
  `ImageResolver`, `CaptionServing`, and `AltPatcher`.

  `scan/2` returns results only for images that were *missing* alt text.
  Images that already have a non-empty alt are not included.
  """

  alias FastAlt.{AltPatcher, CaptionServing, FileScanner, HTMLScanner, ImageResolver}

  @type result :: %{
          html_file: String.t(),
          img_src: String.t(),
          img_path: String.t() | nil,
          generated_alt: String.t() | nil,
          patched: boolean(),
          skipped: boolean(),
          skip_reason: String.t() | nil
        }

  @type scan_opts :: [
          patch: boolean(),
          serving: atom() | nil,
          caption_fn: (String.t() -> String.t()) | nil
        ]

  @doc """
  Scans `dir` recursively for HTML files and reports images missing alt text.

  Options:
  - `:patch`       — rewrite HTML files in-place with generated alt text (default: `false`)
  - `:serving`     — name of the `Nx.Serving` process to use for inference
                     (default: `FastAlt.CaptionServing`)
  - `:caption_fn`  — override the caption function entirely; receives an absolute
                     image path and returns a caption string. Takes precedence over
                     `:serving`. Intended for testing.
  """
  @spec scan(dir :: String.t(), opts :: scan_opts()) ::
          {:ok, [result()]} | {:error, term()}
  def scan(dir, opts \\ []) do
    case File.stat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        do_scan(dir, opts)

      {:ok, _} ->
        {:error, "not a directory: #{dir}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_scan(dir, opts) do
    patch? = Keyword.get(opts, :patch, false)
    caption_fn = resolve_caption_fn(opts)

    html_files = FileScanner.find_html_files(dir)

    results =
      html_files
      |> Task.async_stream(&scan_file(&1, caption_fn), timeout: :infinity)
      |> Enum.flat_map(fn {:ok, file_results} -> file_results end)

    results =
      if patch? do
        apply_patches(results)
      else
        results
      end

    {:ok, results}
  end

  defp resolve_caption_fn(opts) do
    case Keyword.get(opts, :caption_fn) do
      nil ->
        serving = Keyword.get(opts, :serving, CaptionServing)
        &CaptionServing.run(&1, serving)

      fun when is_function(fun, 1) ->
        fun
    end
  end

  defp scan_file(html_file, caption_fn) do
    html_binary = File.read!(html_file)
    imgs = HTMLScanner.scan_html(html_binary)

    imgs
    |> Enum.filter(&missing_alt?/1)
    |> Enum.map(&process_img(&1, html_file, caption_fn))
  end

  defp process_img(%{src: src}, html_file, caption_fn) do
    case ImageResolver.resolve(src, html_file) do
      {:ok, img_path} ->
        generated_alt = caption_fn.(img_path)

        %{
          html_file: html_file,
          img_src: src,
          img_path: img_path,
          generated_alt: generated_alt,
          patched: false,
          skipped: false,
          skip_reason: nil
        }

      {:skip, reason} ->
        %{
          html_file: html_file,
          img_src: src,
          img_path: nil,
          generated_alt: nil,
          patched: false,
          skipped: true,
          skip_reason: reason
        }
    end
  end

  defp missing_alt?(%{alt: nil}), do: true
  defp missing_alt?(%{alt: ""}), do: true
  defp missing_alt?(_), do: false

  defp apply_patches(results) do
    patchable =
      results
      |> Enum.reject(& &1.skipped)
      |> Enum.group_by(& &1.html_file)

    patched_srcs =
      patchable
      |> Enum.flat_map(fn {html_file, file_results} ->
        patches = Enum.map(file_results, &{&1.img_src, &1.generated_alt})

        case AltPatcher.patch_file(html_file, patches) do
          :ok -> Enum.map(file_results, & &1.img_src)
          {:error, _} -> []
        end
      end)
      |> MapSet.new()

    Enum.map(results, fn result ->
      if result.img_src in patched_srcs do
        %{result | patched: true}
      else
        result
      end
    end)
  end
end
