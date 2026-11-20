defmodule TavernWeb.ServerComponents.Forums do
  @moduledoc """
  A forum channel's view: its post list, as a list or a gallery, with a search, the sort and
  layout controls and the New post form. An open post shows as its thread.
  """

  use TavernWeb, :html

  import TavernWeb.ServerComponents.Helpers

  attr :server, :map, required: true

  def forum_view(assigns) do
    assigns = assign(assigns, :forum, assigns.server.forum)

    ~H"""
    <div id="forum-view" class={["flex-1 overflow-y-auto", scrollbar_classes()]}>
      <%= if @server.active_thread && @server.active_thread.starter_message do %>
        <div
          id={"forum-post-#{@server.active_thread.id}"}
          phx-hook=".ForumPostOpen"
          class="mx-auto w-full max-w-4xl py-4 pr-3 pl-1 sm:pr-5 sm:pl-3"
        >
          <TavernWeb.ServerComponents.Threads.thread_panel
            server={@server}
            message={@server.active_thread.starter_message}
            thread={@server.active_thread}
          />
        </div>
      <% else %>
        <div class="mx-auto w-full max-w-4xl space-y-4 px-3 py-4 sm:px-5">
          <.forum_toolbar server={@server} forum={@forum} />
          <.post_form :if={@forum.post_form} form={@forum.post_form} />
          <.post_list forum={@forum} />
        </div>
      <% end %>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ForumPostOpen">
      export default {
        // A forum post fills the view and reads like a chat, newest reply last, so opening one
        // shows its latest replies and its composer. The id names the post, so each post mounts anew.
        mounted() {
          requestAnimationFrame(() => this.el.scrollIntoView({block: "end"}))
        }
      }
    </script>
    """
  end

  attr :server, :map, required: true
  attr :forum, :map, required: true

  defp forum_toolbar(assigns) do
    ~H"""
    <div class="flex flex-col gap-3 sm:flex-row sm:items-center">
      <.form
        for={@forum.search_form}
        id="forum-search"
        phx-change="forum_search"
        phx-submit="forum_search"
        class="min-w-0 flex-1 [&_.fieldset]:mb-0"
      >
        <.input
          field={@forum.search_form[:query]}
          type="search"
          placeholder="Search titles, or #tag"
          autocomplete="off"
          phx-debounce="250"
        />
      </.form>

      <div class="flex flex-wrap items-center gap-2">
        <.segmented
          id="forum-tab"
          label="Post status"
          event="forum_tab"
          field="tab"
          current={@forum.tab}
          options={[active: "Active", archived: "Archived"]}
        />
        <.segmented
          id="forum-sort"
          label="Sort posts"
          field="sort"
          current={@forum.view.sort}
          options={[activity: "Latest activity", created: "Newest"]}
        />
        <.segmented
          id="forum-layout"
          label="Post layout"
          field="layout"
          current={@forum.view.layout}
          options={[list: "List", gallery: "Gallery"]}
        />
        <button
          :if={@server.channel_pane.abilities.create_public_threads and is_nil(@forum.post_form)}
          type="button"
          id="new-forum-post"
          phx-click="new_forum_post"
          class="ml-auto inline-flex shrink-0 items-center gap-1 rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white shadow-sm transition hover:bg-violet-400 sm:ml-0"
        >
          <.icon name="hero-plus" class="size-4" /> New post
        </button>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :field, :string, required: true
  attr :event, :string, default: "forum_view"
  attr :current, :atom, required: true
  attr :options, :list, required: true

  defp segmented(assigns) do
    ~H"""
    <div id={@id} role="group" aria-label={@label} class="inline-flex rounded-lg bg-base-100 p-1">
      <button
        :for={{value, text} <- @options}
        type="button"
        id={"#{@id}-#{value}"}
        phx-click={@event}
        phx-value-tab={@field == "tab" && value}
        phx-value-sort={@field == "sort" && value}
        phx-value-layout={@field == "layout" && value}
        aria-pressed={to_string(@current == value)}
        class={[
          "rounded-md px-2.5 py-1 text-[11px] font-semibold whitespace-nowrap transition",
          @current == value && "bg-base-300 text-base-content shadow-sm",
          @current != value && "text-base-content/60 hover:text-base-content"
        ]}
      >
        {text}
      </button>
    </div>
    """
  end

  attr :form, :map, required: true

  defp post_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="forum-post-form"
      phx-change="validate_forum_post"
      phx-submit="create_forum_post"
      class="rounded-xl border border-base-300 bg-base-100 p-4 shadow-sm"
    >
      <p class="mb-3 text-[11px] font-bold uppercase tracking-[0.18em] text-base-content/50">
        New post
      </p>
      <.input field={@form[:title]} type="text" label="Title" maxlength="40" autocomplete="off" />
      <.input
        field={@form[:body]}
        type="textarea"
        label="Message"
        rows="5"
        placeholder="Say what this post is about. A #word becomes a tag."
      />
      <div class="flex items-center justify-end gap-2">
        <button
          type="button"
          id="cancel-forum-post"
          phx-click="cancel_forum_post"
          class="rounded-md px-3 py-1.5 text-xs font-semibold text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
        >
          Cancel
        </button>
        <button
          type="submit"
          id="submit-forum-post"
          phx-disable-with="Posting..."
          class="rounded-md bg-violet-500 px-3 py-1.5 text-xs font-semibold text-white transition hover:bg-violet-400"
        >
          Post
        </button>
      </div>
    </.form>
    """
  end

  attr :forum, :map, required: true

  defp post_list(assigns) do
    ~H"""
    <p
      :if={@forum.entries == []}
      id="forum-empty"
      class="rounded-xl border border-dashed border-base-300 bg-base-100 px-4 py-10 text-center text-sm text-base-content/60"
    >
      {cond do
        String.trim(@forum.query) != "" -> "No posts match that search."
        @forum.tab == :archived -> "No archived posts."
        true -> "No posts yet. Start the first one."
      end}
    </p>

    <ul
      id="forum-posts"
      data-layout={@forum.view.layout}
      class={[
        @forum.view.layout == :list && "space-y-2",
        @forum.view.layout == :gallery && "grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3"
      ]}
    >
      <li
        :for={entry <- @forum.entries}
        id={"forum-post-#{entry.thread.id}"}
        class="group overflow-hidden rounded-xl border border-base-300 bg-base-100 transition hover:border-base-content/20 hover:shadow-md"
      >
        <.link
          :if={@forum.view.layout == :gallery}
          patch={thread_path(@forum.channel, entry.thread)}
          id={"forum-post-image-#{entry.thread.id}"}
          class="block aspect-video bg-base-200"
          tabindex="-1"
        >
          <img
            :if={entry.image_url}
            src={entry.image_url}
            alt=""
            loading="lazy"
            class="size-full object-cover transition group-hover:scale-[1.02]"
          />
          <span
            :if={is_nil(entry.image_url)}
            class="flex size-full items-center justify-center text-base-content/25"
          >
            <.icon name="hero-chat-bubble-bottom-center-text" class="size-10" />
          </span>
        </.link>

        <div class="px-4 py-3">
          <div class="flex items-start justify-between gap-3">
            <.link
              patch={thread_path(@forum.channel, entry.thread)}
              id={"forum-post-open-#{entry.thread.id}"}
              class="min-w-0 text-sm font-semibold text-base-content hover:text-primary"
            >
              <span class="line-clamp-2">{thread_title(entry.thread)}</span>
            </.link>
          </div>

          <p
            :if={@forum.view.layout == :list && entry.starter}
            class="mt-1 line-clamp-2 text-xs text-base-content/60"
          >
            {entry.starter.body}
          </p>

          <div :if={entry.thread.hashtags != []} class="mt-2 flex flex-wrap gap-1">
            <button
              :for={tag <- entry.thread.hashtags}
              type="button"
              id={"forum-post-tag-#{entry.thread.id}-#{tag}"}
              phx-click="forum_tag"
              phx-value-tag={tag}
              class="rounded-full bg-primary/10 px-2 py-0.5 text-[11px] font-semibold text-primary transition hover:bg-primary/20"
            >
              #{tag}
            </button>
          </div>

          <div class="mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-[11px] text-base-content/55">
            <span :if={entry.starter} class="font-semibold text-base-content/75">
              {entry.starter.author.display_name}
            </span>
            <span id={"forum-post-replies-#{entry.thread.id}"}>
              {reply_count_label(entry.reply_count)}
            </span>
            <span>{message_timestamp(entry.last_activity_at)}</span>
            <span
              :if={entry.top_reaction}
              id={"forum-post-reaction-#{entry.thread.id}"}
              class="inline-flex items-center gap-1 rounded-full border border-base-300 px-1.5 py-0.5 text-base-content/70"
            >
              <span :if={is_nil(entry.top_reaction.emoji_id)}>
                {entry.top_reaction.emoji_unicode}
              </span>
              <img
                :if={entry.top_reaction.emoji && entry.top_reaction.emoji.asset}
                src={Tavern.Chat.asset_url(entry.top_reaction.emoji.asset)}
                alt={entry.top_reaction.emoji.name}
                class="size-3.5 rounded object-cover"
              />
              {entry.top_reaction.count}
            </span>
          </div>
        </div>
      </li>
    </ul>

    <div :if={@forum.next} class="pt-1">
      <button
        type="button"
        id="forum-more"
        phx-click="forum_more"
        phx-disable-with="Loading..."
        class="w-full rounded-md border border-base-300 px-3 py-2 text-xs font-semibold text-base-content/75 transition hover:bg-base-100 hover:text-base-content"
      >
        Load more
      </button>
    </div>
    """
  end
end
