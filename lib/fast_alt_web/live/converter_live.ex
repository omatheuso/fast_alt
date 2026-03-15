defmodule FastAltWeb.ConverterLive do
  use FastAltWeb, :live_view

  require Logger

  @accepted_types ~w(.jpg .jpeg .png .bmp .gif .webp .tiff)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       state: :idle,
       caption: "",
       error: nil
     )
     |> allow_upload(:image,
       accept: @accepted_types,
       max_entries: 1,
       max_file_size: 20_000_000
     )}
  end

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("upload", _params, socket) do
    liveview_pid = self()

    entries =
      consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
        ext = Path.extname(entry.client_name)
        dest = Path.join(System.tmp_dir!(), "img_upload_#{:erlang.unique_integer([:positive])}#{ext}")
        File.cp!(path, dest)
        {:ok, dest}
      end)

    case entries do
      [image_path] ->
        Task.Supervisor.start_child(FastAlt.TaskSupervisor, fn ->
          process_image(image_path, liveview_pid)
        end)

        {:noreply, assign(socket, state: :processing, error: nil, caption: "")}

      _ ->
        {:noreply, assign(socket, error: "Please select an image file")}
    end
  end

  @impl true
  def handle_event("reset", _params, socket) do
    {:noreply, assign(socket, state: :idle, caption: "", error: nil)}
  end

  @impl true
  def handle_info({:inference_complete, caption}, socket) do
    {:noreply, assign(socket, state: :done, caption: caption)}
  end

  @impl true
  def handle_info({:processing_failed, reason}, socket) do
    {:noreply, assign(socket, state: :idle, error: reason)}
  end

  defp process_image(image_path, liveview_pid) do
    Logger.info("[ConverterLive] process_image started — #{image_path}")

    try do
      caption = FastAlt.MarkdownServing.run(image_path)
      Logger.info("[ConverterLive] inference done — #{String.length(caption)} chars")
      send(liveview_pid, {:inference_complete, caption})
    rescue
      e ->
        Logger.error("[ConverterLive] inference failed: #{Exception.message(e)}")
        send(liveview_pid, {:processing_failed, Exception.message(e)})
    after
      File.rm(image_path)
      Logger.debug("[ConverterLive] cleaned up temp file #{image_path}")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-bold">Image Captioning</h1>
          <p class="text-base-content/60 mt-1">
            Upload an image and get an AI-generated caption
          </p>
        </div>

        <%= if @error do %>
          <div role="alert" class="alert alert-error">
            <.icon name="hero-x-circle" class="size-5" />
            <span>{@error}</span>
          </div>
        <% end %>

        <%= cond do %>
          <% @state == :idle -> %>
            <form id="upload-form" phx-submit="upload" phx-change="validate">
              <div class="card bg-base-200 border-2 border-dashed border-base-300">
                <div class="card-body items-center text-center py-12">
                  <.icon name="hero-photo" class="size-12 text-base-content/30" />
                  <p class="text-base-content/60 mt-2">Drop an image or click to browse</p>
                  <p class="text-xs text-base-content/40">
                    JPG, PNG, WebP, GIF, BMP, TIFF · Max 20 MB
                  </p>
                  <.live_file_input upload={@uploads.image} class="file-input file-input-bordered mt-4" />

                  <%= for entry <- @uploads.image.entries do %>
                    <div class="w-full mt-2 space-y-1">
                      <div class="text-sm font-medium">{entry.client_name}</div>
                      <progress
                        class="progress progress-primary w-full"
                        value={entry.progress}
                        max="100"
                      />
                    </div>
                  <% end %>
                </div>
              </div>

              <button
                type="submit"
                class="btn btn-primary w-full mt-4"
                disabled={@uploads.image.entries == []}
              >
                Generate Caption
              </button>
            </form>
          <% @state == :processing -> %>
            <div class="card bg-base-200">
              <div class="card-body items-center text-center py-12">
                <span class="loading loading-spinner loading-lg text-primary"></span>
                <p class="font-medium mt-4">Running inference…</p>
                <p class="text-xs text-base-content/50 mt-1">This may take a moment</p>
              </div>
            </div>
          <% @state == :done -> %>
            <div class="card bg-base-200">
              <div class="card-body">
                <div class="flex items-center justify-between mb-4">
                  <div class="flex items-center gap-2">
                    <.icon name="hero-check-circle" class="size-5 text-success" />
                    <span class="font-medium">Caption generated</span>
                  </div>
                  <div class="flex gap-2">
                    <button
                      onclick="navigator.clipboard.writeText(document.getElementById('caption-output').value)"
                      class="btn btn-sm btn-ghost"
                    >
                      <.icon name="hero-clipboard-document" class="size-4" /> Copy
                    </button>
                    <button phx-click="reset" class="btn btn-sm btn-primary">
                      Try another
                    </button>
                  </div>
                </div>

                <textarea
                  id="caption-output"
                  readonly
                  class="textarea textarea-bordered font-mono text-sm w-full h-48 resize-y"
                >{@caption}</textarea>
              </div>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end
end
