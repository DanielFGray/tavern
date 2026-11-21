const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function login(page) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass', next: '/?channel=general' }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
}

async function post(request, body) {
  const { message } = await command(request, 'create_message', { channel_slug: 'general', username: 'e2e_user', body })
  return message
}

test('opening a thread expands it under its starter and keeps the channel around it', async ({ page, request }) => {
  const stamp = Date.now()
  await login(page)

  const before = await post(request, `before ${stamp}`)
  const starter = await post(request, `starter ${stamp}`)
  const after = await post(request, `after ${stamp}`)
  await expect(page.locator(`#messages-${after.id}`)).toBeVisible()

  // Start the thread from the starter's action bar and reply in it.
  await page.locator(`#message-list [data-markdown-source="starter ${stamp}"]`).click()
  await page.locator(`#create-thread-${starter.id}`).click()
  const composer = page.locator('#thread-message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`reply ${stamp}`)
  await page.locator('#send-thread-message-button').click()
  await expect(page.locator(`#thread-panel-${starter.id}`, { hasText: `reply ${stamp}` })).toBeVisible()

  // Collapsing leaves a chip that counts the reply and previews it, not the starter's text.
  await page.locator(`#close-thread-${starter.id}`).click()
  const chip = page.locator(`#thread-summary-${starter.id}`)
  await expect(chip).toContainText('1 reply')
  await expect(page.locator(`#thread-latest-reply-${starter.id}`)).toContainText(`reply ${stamp}`)
  await expect(chip).not.toContainText(`starter ${stamp}`)

  // Expanding keeps the starter where it was, with the other messages above and below it.
  const starterRow = page.locator(`#messages-${starter.id}`)
  const top = (await starterRow.boundingBox()).y
  await chip.click()
  const panel = page.locator(`#thread-panel-${starter.id}`)
  await expect(panel).toBeVisible()
  await expect(page.locator(`#messages-${before.id}`)).toBeVisible()
  await expect(page.locator(`#messages-${after.id}`)).toBeAttached()
  expect(Math.abs((await starterRow.boundingBox()).y - top)).toBeLessThan(40)

  // The panel sits between the starter and the next message.
  const panelBox = await panel.boundingBox()
  expect((await starterRow.boundingBox()).y).toBeLessThan(panelBox.y)
  expect(panelBox.y).toBeLessThan((await page.locator(`#messages-${after.id}`).boundingBox()).y)

  await page.locator(`#close-thread-${starter.id}`).click()
  await expect(panel).toHaveCount(0)
  await expect(chip).toBeVisible()
})

// A channel long enough to scroll, whose newest message is a thread starter, viewed at the bottom.
async function longChannelWithThread(page, request) {
  const stamp = Date.now()
  const slug = `scroll-${stamp}`
  await command(request, 'ensure_channel', { slug })
  const messages = []
  for (let i = 0; i < 40; i++) {
    const { message } = await command(request, 'create_message', { channel_slug: slug, username: 'e2e_user', body: `filler ${i} ${stamp}` })
    messages.push(message)
  }
  const { message: starter } = await command(request, 'create_message', { channel_slug: slug, username: 'e2e_user', body: `starter ${stamp}` })
  await login(page)
  await page.goto(`/?channel=${slug}`)
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
  await expect(page.locator(`#messages-${starter.id}`)).toBeVisible()

  await page.locator(`#message-list [data-markdown-source="starter ${stamp}"]`).click()
  await page.locator(`#create-thread-${starter.id}`).click()
  const composer = page.locator('#thread-message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`reply ${stamp}`)
  await page.locator('#send-thread-message-button').click()
  await expect(page.locator(`#thread-panel-${starter.id}`, { hasText: `reply ${stamp}` })).toBeVisible()
  await page.locator(`#close-thread-${starter.id}`).click()
  await expect(page.locator(`#thread-panel-${starter.id}`)).toHaveCount(0)

  // Start from a fresh load, at the bottom, with the starter as the newest message.
  await page.goto(`/?channel=${slug}`)
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
  await expect(page.locator(`#messages-${starter.id}`)).toBeVisible()
  // The channel scrolls inside its own region, so the page does not, and the composer stays on
  // screen. The reader starts at the bottom.
  const scrolls = await page.evaluate(() => {
    const region = document.querySelector("#message-scroll-region")
    region.scrollTop = region.scrollHeight
    const page = document.scrollingElement
    return { region: region.scrollHeight > region.clientHeight, page: page.scrollHeight > page.clientHeight }
  })
  expect(scrolls).toEqual({ region: true, page: false })
  await expect(page.locator("#message-form")).toBeInViewport()
  await expect(page.locator(`#messages-${starter.id}`)).toBeInViewport()
  return { stamp, slug, starter, previous: messages[messages.length - 1] }
}

test('opening and closing a thread at the bottom keeps the starter in place', async ({ page, request }, testInfo) => {
  const { stamp, slug, starter, previous } = await longChannelWithThread(page, request)
  const starterRow = page.locator(`#messages-${starter.id}`)
  const pill = page.locator(`#thread-summary-${starter.id}`)
  const shot = name => page.screenshot({ path: `${process.env.SHOT_DIR || '/tmp'}/${testInfo.project.name}-${name}.png` })
  await shot('before-open')

  const top = (await starterRow.boundingBox()).y
  await pill.click()
  const panel = page.locator(`#thread-panel-${starter.id}`)
  await expect(panel).toBeVisible()
  await page.waitForTimeout(300)
  await shot('after-open')
  // The pinned composer gains a "Replying in thread" strip, so the transcript above it shrinks by
  // that strip's height. The starter must stay within that shift of where it was.
  expect(Math.abs((await starterRow.boundingBox()).y - top)).toBeLessThan(80)
  await expect(page.locator(`#messages-${previous.id}`)).toBeInViewport()
  await expect(starterRow).toBeInViewport()

  // One composer: the thread has none of its own, and the pinned one says where it sends.
  await expect(page.locator('#message-form')).toHaveCount(0)
  await expect(page.locator('#thread-message-form')).toHaveCount(1)
  await expect(page.locator('#thread-target-indicator')).toContainText('Replying in thread')
  await expect(panel.locator('#thread-message-form')).toHaveCount(0)

  // The pill stays and toggles the thread.
  await expect(pill).toHaveAttribute('aria-expanded', 'true')
  await pill.click()
  await expect(panel).toHaveCount(0)
  await expect(pill).toHaveAttribute('aria-expanded', 'false')
  await page.waitForTimeout(300)
  expect(Math.abs((await starterRow.boundingBox()).y - top)).toBeLessThan(40)
  await expect(page).toHaveURL(new RegExp(`channel=${slug}$`))

  // New messages at the end of the channel still follow the bottom.
  const { message: fresh } = await command(request, 'create_message', { channel_slug: slug, username: 'e2e_user', body: `fresh ${stamp}` })
  await expect(page.locator(`#messages-${fresh.id}`)).toBeInViewport()
})

// The open thread renders inside its starter's row of the channel stream, so this guards that a
// thread typing change renders that row again.
test("another member's typing shows in the open thread", async ({ page, request, browser }) => {
  const stamp = Date.now()
  await login(page)
  const starter = await post(request, `typing starter ${stamp}`)
  await page.locator(`#message-list [data-markdown-source="typing starter ${stamp}"]`).click()
  await page.locator(`#create-thread-${starter.id}`).click()
  await expect(page.locator(`#thread-panel-${starter.id}`)).toBeVisible()
  await page.locator(`#close-thread-${starter.id}`).click()
  const chip = page.locator(`#thread-summary-${starter.id}`)
  await expect(chip).toHaveAttribute('href', /thread=/)
  const threadPath = await chip.getAttribute('href')
  await chip.click()
  await expect(page.locator(`#thread-panel-${starter.id}`)).toBeVisible()

  const typistContext = await browser.newContext()
  const typist = await typistContext.newPage()
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email: 'e2e-typist@example.com', username: 'e2e_typist', display_name: 'Thread Typist', password: 'supersecurepass', next: '/?channel=general' }))
  await typist.goto(url.toString())
  await expect(typist.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
  await typist.goto(new URL(threadPath, baseURL).toString())
  const composer = typist.locator('#thread-message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially('almost done')

  await expect(page.locator(`#thread-typing-indicator-${starter.id}`)).toContainText('Thread Typist is typing')
  await typistContext.close()
})
