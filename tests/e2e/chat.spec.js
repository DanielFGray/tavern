const { test, expect } = require('@playwright/test')

const { baseURL, command: runServerCommand, login, openSidebar, openUserMenu, unique: runSuffix } = require('./support')

test.beforeEach(async ({ page }) => {
  await page.addInitScript(() => {
    const notifications = []

    class FakeNotification {
      static permission = 'granted'

      constructor(title, options = {}) {
        this.title = title
        this.options = options
        notifications.push({ title, ...options })
      }

      close() {}
    }

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'hidden',
    })

    window.Notification = FakeNotification
    window.__tavernNotifications = notifications
  })
})

test('desktop user can switch channels and send a chat message', async ({ page, isMobile }) => {
  test.skip(isMobile, 'desktop-only interaction flow')

  const displayName = 'E2E User'
  const unique = `${Date.now()}`.slice(-6)
  const message = `Hello **bold** @e2e_user`
  const code = `console.log("${unique}")`
  const link = `https://example.com/${unique}`

  await login(page)
  await expect(page.locator('#channel-link-general')).toBeVisible()

  await page.locator('#channel-link-engineering').click()
  await expect(page).toHaveURL(/\?channel=engineering$/)
  await expect(page.locator('#message-form')).toBeVisible()
  await expect(page.locator('#rich-composer-shell')).not.toHaveClass(/is-expanded/)

  const composer = page.locator('#message-form [contenteditable="true"]').first()

  await expect(composer).toBeVisible()
  await composer.click()
  await expect(page.locator('#rich-composer-shell')).toHaveClass(/is-focused/)
  await composer.pressSequentially(message)
  await page.getByRole('button', { name: 'Code block' }).click()
  await composer.pressSequentially(code)
  await page.getByRole('button', { name: 'Code block' }).click()
  await composer.press('Shift+Enter')
  await composer.pressSequentially(link)
  await page.getByRole('button', { name: 'Send message' }).click()

  const sentMessage = page.locator(`#message-list [data-markdown-source*="${unique}"]`).last()
  await expect(sentMessage).toContainText('Hello')
  await expect(sentMessage).toContainText('bold')
  await expect(sentMessage).toContainText('@e2e_user')
  await expect(sentMessage).toContainText(code)
  await expect(sentMessage).toContainText(link)
  await expect(page.locator('#message-list')).toContainText(displayName)
})

test('Enter sends the message and Shift+Enter starts a new line', async ({ page }, testInfo) => {
  const unique = runSuffix(testInfo)
  await login(page)

  const composer = page.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`first ${unique}`)
  await composer.press('Shift+Enter')
  await composer.pressSequentially(`second ${unique}`)
  await expect(page.locator(`#message-list [data-markdown-source*="${unique}"]`)).toHaveCount(0)

  await composer.press('Enter')

  const sent = page.locator(`#message-list [data-markdown-source*="${unique}"]`)
  await expect(sent).toHaveCount(1)
  await expect(sent).toHaveAttribute('data-markdown-source', `first ${unique}\nsecond ${unique}`)
  await expect(composer).toHaveText('')
})

test('mobile user can open drawers and reaction bottom sheet', async ({ page, isMobile }, testInfo) => {
  test.skip(!isMobile, 'mobile-only interaction flow')

  const { message } = await runServerCommand(page.request, 'create_message', {
    channel_slug: 'engineering',
    username: 'e2e_user',
    body: `react to me ${runSuffix(testInfo)}`,
  })

  await login(page)

  await page.locator('#open-mobile-sidebar').click()
  await expect(page.locator('#mobile-channel-drawer')).toHaveClass(/translate-x-0/)
  await page.locator('#channel-link-engineering').click()
  await expect(page).toHaveURL(/\?channel=engineering$/)

  await page.locator('#open-mobile-members').click()
  await expect(page.locator('#mobile-members-drawer')).toHaveClass(/translate-x-0/)
  await expect(page.locator('#mobile-members-drawer')).toContainText('Members')
  await page.locator('#close-mobile-members').click()

  // The message toolbar stays hidden on a touch screen until the message is tapped.
  await page.locator(`#messages-${message.id} [phx-click="toggle_message_controls"]`).click()
  const reactionButton = page.locator(`#open-reaction-picker-${message.id}`)
  await reactionButton.click()

  const reactionSheet = page.locator('[id^="reaction-picker-"]').first()
  await expect(reactionSheet).toBeVisible()
  await expect(reactionSheet).toHaveClass(/fixed/)

  await page.locator('[id^="reaction-picker-default-"]').first().click()
  await expect(page.locator('[id^="reaction-"]').first()).toBeVisible()
})

test('settings trigger is visible and navigates to authenticated settings route', async ({ page }) => {
  await login(page)

  await openUserMenu(page)
  await page.locator('#user-menu-settings').click()
  await expect(page).toHaveURL(/\/settings$/)
  await expect(page.locator('#settings-panel-title')).toBeVisible()

  const guest = await page.context().browser().newPage()
  await guest.goto(`${baseURL}/settings`)
  await expect(guest).toHaveURL(/\/login$/)
  await guest.close()
})

test('server branding updates settings and shell surfaces', async ({ page }) => {
  await runServerCommand(page.request, 'set_server_name', { name: 'Tavern' })
  await login(page)

  await openUserMenu(page)
  await page.locator('#user-menu-settings').click()
  await expect(page).toHaveURL(/\/settings$/)

  await page.locator('#settings-tab-server').click()
  // A long checkbox label must wrap: a nowrap one made this tab wider than a phone screen.
  await expect(page.locator('#accept-invite-requests')).toBeVisible()
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth)
  expect(overflow).toBeLessThanOrEqual(0)
  await page.getByLabel('Server name').fill('Orbit HQ')
  await page.getByRole('button', { name: 'Save server settings' }).click()

  await expect(page.locator('#flash-group')).toContainText('Server settings updated.')
  await expect(page.getByLabel('Server name')).toHaveValue('Orbit HQ')

  await page.locator('#back-to-chat-link').click()
  await expect(page).toHaveURL(/\/($|\?)/)
  await expect(page.locator('#mobile-channel-drawer')).toContainText('Orbit HQ')
})

// A 1x1 transparent PNG.
const tinyPng = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
)

test('owner uploads a custom emoji from the browser and deletes it', async ({ page }) => {
  await login(page)
  await page.goto('/settings?tab=emoji')
  await expect(page.locator('#settings-view-emoji')).toBeVisible()

  await page.locator('#emoji-form').getByLabel('Name', { exact: true }).fill('e2e wave')
  await page.locator('#emoji-form').getByLabel('Shortcode').fill('e2ewave')
  await page.locator('#emoji-form input[type=file]').setInputFiles({
    name: 'wave.png',
    mimeType: 'image/png',
    buffer: tinyPng,
  })
  await page.getByRole('button', { name: 'Save emoji' }).click()

  const image = page.locator('[id^="manage-emoji-"] img[src*="/uploads/"]')
  await expect(image).toHaveCount(1)
  const src = new URL(await image.getAttribute('src'), baseURL).toString()
  const stored = await page.request.get(src)
  expect(stored.status()).toBe(200)
  expect(Buffer.compare(await stored.body(), tinyPng)).toBe(0)

  page.once('dialog', (dialog) => dialog.accept())
  await page.locator('[id^="delete-emoji-"]').click()
  await expect(image).toHaveCount(0)
  expect((await page.request.get(src)).status()).toBe(404)
})

test('inactive channel mention triggers browser notification', async ({ browser }) => {
  const unique = `${Date.now()}`.slice(-6)
  const authorEmail = `test_notify_${unique}@example.com`
  const authorUsername = `test_notify_${unique}`
  const authorDisplayName = `Notify ${unique}`
  const password = 'supersecurepass'
  const author = await browser.newPage()
  const receiver = await browser.newPage()

  await receiver.addInitScript(() => {
    const notifications = []

    class FakeNotification {
      static permission = 'granted'

      constructor(title, options = {}) {
        this.title = title
        this.options = options
        notifications.push({ title, ...options })
      }

      close() {}
    }

    Object.defineProperty(document, 'visibilityState', {
      configurable: true,
      get: () => 'hidden',
    })

    window.Notification = FakeNotification
    window.__tavernNotifications = notifications
  })

  await login(author, { email: authorEmail, username: authorUsername, password, display_name: authorDisplayName })
  await login(receiver)

  await openSidebar(author)
  await author.locator('#channel-link-engineering').click()
  await expect(author).toHaveURL(/\?channel=engineering$/)

  const composer = author.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`ping @e2e_user ${unique}`)
  await author.getByRole('button', { name: 'Send message' }).click()

  await expect(receiver.locator('#channel-mention-engineering')).toBeVisible()

  await expect.poll(async () => {
    return await receiver.evaluate(() => window.__tavernNotifications || [])
  }).toContainEqual(
    expect.objectContaining({
      title: expect.stringContaining('mentioned you in #Engineering'),
      body: expect.stringContaining(`ping @e2e_user ${unique}`),
    })
  )

  await author.close()
  await receiver.close()
})
