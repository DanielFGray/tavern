const { test, expect } = require('@playwright/test')

const { command, login, owner, unique } = require('./support')

// Pinning from a message's menu marks the row, posts a pin line, and lists the message in the
// Pins drawer, where Unpin takes it out again.

test('a pinned message shows on its row, in a pin line and in the drawer', async ({ page, request }, testInfo) => {
  const slug = `pins-${unique(testInfo)}`
  const body = `pin me ${unique(testInfo)}`
  await command(request, 'ensure_channel', { slug, name: slug })
  const { message } = await command(request, 'create_message', { channel_slug: slug, username: owner.username, body })

  await login(page, { next: `/?channel=${slug}` })
  const row = page.locator(`#messages-${message.id}`)
  await row.locator('[data-markdown-source]').click()
  await page.locator(`#open-message-actions-${message.id}`).click()
  await page.locator(`#pin-message-${message.id}`).click()

  await expect(page.locator(`#message-pinned-${message.id}`)).toBeVisible()
  const line = page.locator('[id^="pin-line-open-"]')
  await expect(line).toHaveCount(1)
  await expect(page.locator('#message-list')).toContainText(`pinned a message: ${body}`)

  await line.click()
  const drawer = page.locator('#pins')
  await expect(drawer).toBeVisible()
  await expect(drawer.locator(`#pins-row-${message.id}`)).toContainText(body)

  await page.locator(`#pins-row-${message.id}`).hover()
  await page.locator(`#pins-unpin-${message.id}`).click()
  await expect(page.locator('#pins-empty')).toBeVisible()
  await expect(page.locator(`#message-pinned-${message.id}`)).toHaveCount(0)

  await page.keyboard.press('Escape')
  await expect(drawer).toHaveCount(0)
})
