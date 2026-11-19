const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'
const owner = { email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass' }

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function post(request, slug, body) {
  const { message } = await command(request, 'create_message', { channel_slug: slug, username: owner.username, body })
  return message
}

// Records the id of every element the page animates with Element.animate, from before the app loads.
async function recordAnimations(page) {
  await page.addInitScript(() => {
    window.__animated = []
    const animate = Element.prototype.animate
    Element.prototype.animate = function (...args) {
      window.__animated.push(this.id)
      return animate.apply(this, args)
    }
  })
}

const animated = page => page.evaluate(() => window.__animated)

async function openApp(page, request, slugs, { reducedMotion } = {}) {
  for (const slug of slugs) await command(request, 'ensure_channel', { slug, name: slug, kind: 'text' })
  if (reducedMotion) await page.emulateMedia({ reducedMotion })
  await recordAnimations(page)
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ ...owner, next: `/?channel=${slugs[0]}` }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
}

async function switchTo(page, slug) {
  const toggle = page.locator('#open-mobile-sidebar')
  if (await toggle.isVisible().catch(() => false)) await toggle.click()
  await page.locator(`#channel-link-${slug}`).click()
  await expect(page).toHaveURL(new RegExp(`channel=${slug}$`))
}

test('a live message animates in; loaded, switched-to and edited rows do not', async ({ page, request }) => {
  const stamp = Date.now()
  const a = `enter-a-${stamp}`
  const b = `enter-b-${stamp}`
  const bRows = []
  await command(request, 'ensure_channel', { slug: a, name: a, kind: 'text' })
  await command(request, 'ensure_channel', { slug: b, name: b, kind: 'text' })
  const loaded = await post(request, a, `loaded ${stamp}`)
  for (let i = 0; i < 5; i++) bRows.push(await post(request, b, `b ${i} ${stamp}`))

  await openApp(page, request, [a, b])
  await expect(page.locator(`#messages-${loaded.id}`)).toBeVisible()
  expect(await animated(page)).toEqual([])

  // A message that arrives while the channel is open.
  const live = await post(request, a, `live ${stamp}`)
  await expect(page.locator(`#messages-${live.id}`)).toBeVisible()
  await expect.poll(() => animated(page)).toEqual([`messages-${live.id}`])

  // Switching to a channel with rows, and back, animates none of them.
  await switchTo(page, b)
  await expect(page.locator(`#messages-${bRows[4].id}`)).toBeVisible()
  await switchTo(page, a)
  await expect(page.locator(`#messages-${live.id}`)).toBeVisible()
  expect(await animated(page)).toEqual([`messages-${live.id}`])

  // Editing re-renders the row in place.
  await page.locator(`#messages-${live.id} [data-markdown-source]`).click()
  await page.locator(`#open-message-actions-${live.id}`).click()
  await page.locator(`#edit-message-${live.id}`).click()
  await page.locator(`#edit-message-body-${live.id}`).fill(`edited ${stamp}`)
  await page.locator(`#edit-message-form-${live.id} button[type="submit"]`).click()
  await expect(page.locator(`#messages-${live.id} [data-markdown-source="edited ${stamp}"]`)).toBeVisible()
  expect(await animated(page)).toEqual([`messages-${live.id}`])
})

test('a thread panel and its pill animate when the reader starts a thread, not when it is restored', async ({ page, request }) => {
  const stamp = Date.now()
  const slug = `enter-thread-${stamp}`
  await command(request, 'ensure_channel', { slug, name: slug, kind: 'text' })
  const starter = await post(request, slug, `starter ${stamp}`)

  await openApp(page, request, [slug])
  await expect(page.locator(`#messages-${starter.id}`)).toBeVisible()

  await page.locator(`#messages-${starter.id} [data-markdown-source]`).click()
  await page.locator(`#create-thread-${starter.id}`).click()
  const panel = page.locator(`#thread-panel-${starter.id}`)
  await expect(panel).toBeVisible()
  await expect.poll(() => animated(page)).toContain(`thread-panel-${starter.id}`)

  const composer = page.locator('#thread-message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`reply ${stamp}`)
  await page.locator('#send-thread-message-button').click()
  await expect(panel.locator('[data-markdown-source]', { hasText: `reply ${stamp}` })).toBeVisible()
  await expect.poll(() => animated(page)).toContain(`thread-summary-${starter.id}`)

  // Reopening it from its pill, in the same channel, animates the panel again.
  await page.locator(`#close-thread-${starter.id}`).click()
  await expect(panel).toHaveCount(0)
  await page.evaluate(() => { window.__animated.length = 0 })
  await page.locator(`#thread-summary-${starter.id}`).click()
  await expect(panel).toBeVisible()
  await expect.poll(() => animated(page)).toEqual([`thread-panel-${starter.id}`])

  // The same thread restored from its URL animates nothing.
  await page.locator(`#close-thread-${starter.id}`).click()
  await expect(panel).toHaveCount(0)
  const threadHref = await page.locator(`#thread-summary-${starter.id}`).getAttribute('href')
  expect(threadHref).toContain('thread=')
  await page.goto(threadHref)
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
  await expect(page.locator(`#thread-panel-${starter.id}`)).toBeVisible()
  expect(await page.evaluate(() => window.__animated)).toEqual([])
})

test('nothing animates when the reader prefers reduced motion', async ({ page, request }) => {
  const stamp = Date.now()
  const slug = `enter-reduced-${stamp}`
  await openApp(page, request, [slug], { reducedMotion: 'reduce' })

  const live = await post(request, slug, `live ${stamp}`)
  await expect(page.locator(`#messages-${live.id}`)).toBeVisible()
  expect(await animated(page)).toEqual([])
})
