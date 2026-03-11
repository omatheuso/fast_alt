defmodule FastAlt.MarkdownServing do
  require Logger

  @moduledoc """
  Bumblebee vision-language serving for converting document page images to Markdown.

  Uses BLIP image captioning (Salesforce/blip-image-captioning-base). Bumblebee 0.6.x
  does not support moondream2's architecture; this is the best available option within
  Bumblebee's current model registry.

  The serving is registered under this module's name via `Nx.Serving` and started
  once in the supervision tree. Call `run/1` with an image file path to convert a
  page to Markdown.
  """

  @model_id "Salesforce/blip-image-captioning-base"

  @prompt """
  Explain what is written in this document image.
  """

  @doc """
  Builds and returns the `Nx.Serving` struct. Called once at application boot
  from the supervision tree.
  """
  def serving do
    Logger.info("[MarkdownServing] loading model #{@model_id} …")
    {:ok, model_info} = Bumblebee.load_model({:hf, @model_id})
    Logger.info("[MarkdownServing] model loaded")

    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, @model_id})
    Logger.info("[MarkdownServing] featurizer loaded")

    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_id})
    Logger.info("[MarkdownServing] tokenizer loaded")

    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, @model_id})
    Logger.info("[MarkdownServing] generation config loaded")

    serving =
      Bumblebee.Vision.image_to_text(model_info, featurizer, tokenizer, generation_config,
        defn_options: [compiler: EXLA],
        compile: [batch_size: 1]
      )

    Logger.info("[MarkdownServing] serving built, starting process …")
    serving
  end

  @supported_exts ~w(.jpg .jpeg .png .bmp .gif)

  @doc """
  Runs inference on `image_path` and returns the generated text string.
  """
  def run(image_path) do
    ext = image_path |> Path.extname() |> String.downcase()

    unless ext in @supported_exts do
      raise "format #{ext} is not supported. Supported formats: #{Enum.join(@supported_exts, ", ")}"
    end

    Logger.debug("[MarkdownServing] reading image: #{image_path}")
    image = StbImage.read_file!(image_path)

    Logger.debug(
      "[MarkdownServing] image loaded — shape: #{inspect(image.shape)}, type: #{inspect(image.type)}"
    )

    Logger.debug("[MarkdownServing] sending to batched_run …")

    result = Nx.Serving.batched_run(__MODULE__, %{image: image, text: @prompt})

    Logger.debug("[MarkdownServing] raw result: #{inspect(result)}")

    %{results: [%{text: text}]} = result

    Logger.debug(
      "[MarkdownServing] extracted text (#{String.length(text)} chars): #{inspect(text)}"
    )

    text
  end
end
