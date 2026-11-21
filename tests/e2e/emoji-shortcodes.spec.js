const { test, expect } = require('@playwright/test')

const { login, unique: runSuffix } = require('./support')

const tinyPng = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
  'base64',
)

test('typing a shortcode offers emoji, Enter picks one, and a sent :shortcode: is drawn as the emoji', async ({ page }, testInfo) => {
  const unique = runSuffix(testInfo)
  await login(page)

  const composer = page.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`hi ${unique} :tad`)

  // The list stays closed for a one-letter query and opens for two or more.
  const option = page.locator('body > div.fixed button', { hasText: ':tada:' })
  await expect(option).toBeVisible()
  await expect(option).toContainText('🎉')

  // Enter picks the highlighted emoji instead of sending the message.
  await composer.press('Enter')
  await expect(composer).toContainText('🎉')
  await expect(page.locator(`#message-list [data-markdown-source*="${unique}"]`)).toHaveCount(0)

  await composer.pressSequentially(' and :+1: typed')
  await composer.press('Enter')

  const sent = page.locator(`#message-list [data-markdown-source*="${unique}"]`)
  await expect(sent).toHaveCount(1)
  await expect(sent).toHaveAttribute('data-markdown-source', `hi ${unique} 🎉  and :+1: typed`)
  await expect(sent.locator('span.emoji[aria-label=":+1:"]')).toHaveText('👍')
})

test('code keeps a shortcode as text and an unknown shortcode is left alone', async ({ page }, testInfo) => {
  const unique = runSuffix(testInfo)
  await login(page)

  const composer = page.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`${unique} \`:fire:\` :not_an_emoji_${unique}:`)
  await composer.press('Enter')

  const sent = page.locator(`#message-list [data-markdown-source*="${unique}"]`)
  await expect(sent).toHaveCount(1)
  await expect(sent.locator('code')).toHaveText(':fire:')
  await expect(sent.locator('.emoji')).toHaveCount(0)
})

test('a custom emoji is suggested and drawn as its image', async ({ page }, testInfo) => {
  const unique = runSuffix(testInfo)
  await login(page)
  await page.goto('/settings?tab=emoji')
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)
  await expect(page.locator('#settings-view-emoji')).toBeVisible()

  await page.locator('#emoji-form').getByLabel('Name', { exact: true }).fill('e2e shortcode')
  await page.locator('#emoji-form').getByLabel('Shortcode').fill('e2eblob')
  await page.locator('#emoji-form input[type=file]').setInputFiles({ name: 'blob.png', mimeType: 'image/png', buffer: tinyPng })
  await page.getByRole('button', { name: 'Save emoji' }).click()
  await expect(page.locator('[id^="manage-emoji-"] img[src*="/uploads/"]')).toHaveCount(1)

  await page.goto('/')
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)
  const composer = page.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(`${unique} :e2eb`)
  await expect(page.locator('body > div.fixed button img[src*="/uploads/"]')).toBeVisible()
  await composer.press('Enter')
  await expect(composer.locator('img[data-custom-emoji-id][alt=":e2eblob:"]')).toBeVisible()
  await composer.press('Enter')

  const sent = page.locator(`#message-list [data-markdown-source*="${unique}"]`)
  await expect(sent).toHaveAttribute('data-markdown-source', /<:e2eblob:[0-9a-f-]{36}>/)
  await expect(sent.locator('img.emoji[alt=":e2eblob:"]')).toHaveAttribute('src', /\/uploads\//)

  page.once('dialog', dialog => dialog.accept())
  await page.goto('/settings?tab=emoji')
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)
  await expect(page.locator('#settings-view-emoji')).toBeVisible()
  await page.locator('[id^="delete-emoji-"]').click()
  await expect(page.locator('[id^="manage-emoji-"]')).toHaveCount(0)
})
