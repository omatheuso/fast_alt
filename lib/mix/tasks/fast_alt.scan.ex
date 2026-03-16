defmodule Mix.Tasks.FastAlt.Scan do
  use Mix.Task

  @shortdoc "Scan HTML files for missing alt attributes and optionally patch them"

  @moduledoc """
  Scans a directory of HTML files for `<img>` tags missing `alt` attributes.

  Runs local AI inference (BLIP) on each unresolved image and reports findings.
  Optionally rewrites the HTML files in-place with the generated alt text.

  ## Usage

      mix fast_alt.scan [OPTIONS] <directory>

  ## Options

    * `--patch` / `-p`    — rewrite HTML files in-place with generated alt text
    * `--format` / `-f`   — output format: `text` (default) or `json`
    * `--out`             — write report to a file path instead of stdout

  ## Exit codes

    * `0` — all images already had non-empty alt attributes
    * `1` — one or more images were missing alt (CI lint gate)

  ## Examples

      mix fast_alt.scan ./dist
      mix fast_alt.scan --patch ./dist
      mix fast_alt.scan --format json --out report.json ./dist
  """

  @serving_name FastAlt.CIPipeline.Serving

  @switches [patch: :boolean, format: :string, out: :string]
  @aliases [p: :patch, f: :format]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)

    dir = parse_dir!(args)
    patch? = Keyword.get(opts, :patch, false)
    format = parse_format!(opts)
    out = Keyword.get(opts, :out)

    Mix.Task.run("app.config")

    # Mix.Task.run("app.config") only evaluates config files — it does NOT start OTP
    # applications. We need :bumblebee, :exla, :nx, :inets, and all transitive deps
    # running before CaptionServing.serving/0 contacts HuggingFace or builds the
    # Nx.Serving. Starting :fast_alt itself pulls in the full dependency tree.
    # We suppress the application's own Nx.Serving child so this task's supervisor
    # is the only one holding the serving process.
    Application.put_env(:fast_alt, :start_serving, false)
    Application.ensure_all_started(:fast_alt)

    {:ok, sup} = start_serving_supervisor()

    scan_opts = [patch: patch?, serving: @serving_name]

    results =
      case FastAlt.Scanner.scan(dir, scan_opts) do
        {:ok, results} ->
          results

        {:error, :enoent} ->
          Supervisor.stop(sup)
          Mix.raise("directory not found: #{dir}")

        {:error, reason} ->
          Supervisor.stop(sup)
          Mix.raise("scan failed: #{inspect(reason)}")
      end

    Supervisor.stop(sup)

    report = build_report(dir, results, patch?)
    output = format_report(report, format)
    write_output(output, out)

    if report.summary.missing_alt > 0 do
      System.halt(1)
    else
      System.halt(0)
    end
  end

  defp start_serving_supervisor do
    Supervisor.start_link(
      [
        {Nx.Serving,
         serving: FastAlt.CaptionServing.serving(), name: @serving_name, batch_size: 1}
      ],
      strategy: :one_for_one
    )
  end

  defp parse_dir!([dir | _]), do: dir

  defp parse_dir!([]) do
    Mix.raise(
      "missing required argument: <directory>\nUsage: mix fast_alt.scan [OPTIONS] <directory>"
    )
  end

  defp parse_format!(opts) do
    case Keyword.get(opts, :format, "text") do
      "text" -> :text
      "json" -> :json
      other -> Mix.raise("unknown --format value: #{other}. Use 'text' or 'json'.")
    end
  end

  defp build_report(dir, results, patch?) do
    total_missing = length(results)
    patched = Enum.count(results, & &1.patched)
    skipped = Enum.count(results, & &1.skipped)

    %{
      scan_root: dir,
      summary: %{
        missing_alt: total_missing,
        patched: if(patch?, do: patched, else: 0),
        skipped: skipped
      },
      results: results
    }
  end

  defp format_report(report, :text), do: format_text(report)
  defp format_report(report, :json), do: format_json(report)

  defp format_text(%{scan_root: dir, summary: summary, results: results}) do
    header = "FastAlt scan: #{dir}\n  #{summary.missing_alt} image(s) missing alt\n"

    lines =
      Enum.map(results, fn r ->
        tag = result_tag(r)
        src = r.img_src
        detail = result_detail(r)
        "  #{tag}  #{r.html_file}  →  #{src}  →  #{detail}"
      end)

    Enum.join([header | lines], "\n")
  end

  defp result_tag(%{skipped: true}), do: "[SKIP]   "
  defp result_tag(%{patched: true}), do: "[PATCHED]"
  defp result_tag(_), do: "[FOUND]  "

  defp result_detail(%{skipped: true, skip_reason: reason}), do: reason
  defp result_detail(%{generated_alt: alt}), do: inspect(alt)

  defp format_json(%{scan_root: dir, summary: summary, results: results}) do
    payload = %{
      scan_root: dir,
      summary: summary,
      results:
        Enum.map(results, fn r ->
          %{
            html_file: r.html_file,
            img_src: r.img_src,
            img_path: r.img_path,
            generated_alt: r.generated_alt,
            patched: r.patched,
            skipped: r.skipped,
            skip_reason: r.skip_reason
          }
        end)
    }

    Jason.encode!(payload, pretty: true)
  end

  defp write_output(output, nil), do: Mix.shell().info(output)

  defp write_output(output, path) do
    File.write!(path, output)
    Mix.shell().info("Report written to #{path}")
  end
end
