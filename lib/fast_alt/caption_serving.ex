defmodule FastAlt.CaptionServing do
  require Logger

  @moduledoc """
  Bumblebee vision-language serving for captioning images.

  Uses BLIP image captioning (Salesforce/blip-image-captioning-base). Bumblebee 0.6.x
  does not support moondream2's architecture; this is the best available option within
  Bumblebee's current model registry.

  The serving is registered under this module's name via `Nx.Serving` and started
  once in the supervision tree. Call `run/1` with an image file path to give the image a caption.
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
    Logger.info("[CaptionServing] loading model #{@model_id} …")
    {:ok, model_info} = Bumblebee.load_model({:hf, @model_id})
    Logger.info("[CaptionServing] model loaded")

    {:ok, featurizer} = Bumblebee.load_featurizer({:hf, @model_id})
    Logger.info("[CaptionServing] featurizer loaded")

    {:ok, tokenizer} = Bumblebee.load_tokenizer({:hf, @model_id})
    Logger.info("[CaptionServing] tokenizer loaded")

    {:ok, generation_config} = Bumblebee.load_generation_config({:hf, @model_id})
    Logger.info("[CaptionServing] generation config loaded")

    serving =
      Bumblebee.Vision.image_to_text(model_info, featurizer, tokenizer, generation_config,
        defn_options: [compiler: EXLA],
        compile: [batch_size: 1]
      )

    Logger.info("[CaptionServing] serving built, starting process …")
    serving
  end

  @doc """
  Runs inference on `image_path` and returns the generated caption string.

  Uses `Image` (libvips) for decoding, which supports JPEG, PNG, WebP, AVIF,
  HEIC, TIFF, GIF, BMP, and more. The decoded image is re-encoded as PNG in
  memory and handed to `StbImage` for Bumblebee compatibility.
  """
  def run(image_path) do
    Logger.debug("[CaptionServing] reading image: #{image_path}")

    image =
      with {:ok, vix_image} <- Image.open(image_path),
           {:ok, png_binary} <- Image.write(vix_image, :memory, suffix: ".png") do
        StbImage.read_binary!(png_binary)
      else
        {:error, reason} -> raise "failed to decode image: #{inspect(reason)}"
      end

    Logger.debug(
      "[CaptionServing] image loaded — shape: #{inspect(image.shape)}, type: #{inspect(image.type)}"
    )

    Logger.debug("[CaptionServing] sending to batched_run …")

    result = Nx.Serving.batched_run(__MODULE__, %{image: image, text: @prompt})

    Logger.debug("[CaptionServing] raw result: #{inspect(result)}")

    %{results: [%{text: text}]} = result

    Logger.debug(
      "[CaptionServing] extracted text (#{String.length(text)} chars): #{inspect(text)}"
    )

    text
  end
end
