const { test, expect } = require('@playwright/test')

const { login, owner, unique } = require('./support')

async function sendMessage(page, text) {
  const composer = page.locator('#message-form [contenteditable="true"]').first()
  await composer.click()
  await composer.pressSequentially(text)
  await page.getByRole('button', { name: 'Send message' }).click()
}

test('hovering an author, an @mention or a member row opens the profile card', async ({ page, isMobile }, testInfo) => {
  test.skip(isMobile, 'hover flow; a tap opens the card on a phone')

  const marker = unique(testInfo)
  const bio = `Bio **${marker}** line`

  await login(page)
  await page.goto('/settings?tab=profile')
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)
  await page.locator('#profile-form textarea').fill(bio)
  await page.locator('#profile-form').getByRole('button', { name: 'Save profile' }).click()
  await expect(page.locator('#flash-info')).toContainText('Profile updated.')

  await page.goto('/?channel=general')
  await expect(page.locator('#message-form')).toBeVisible()
  await sendMessage(page, `hello @${owner.username} ${marker}`)

  const row = page.locator(`#message-list [data-markdown-source*="${marker}"]`).last()
  await expect(row).toContainText('hello')

  const card = page.locator('#profile-card')
  await expect(card).toHaveCount(0)

  // Hover the author's name: the card opens after a short delay.
  const authorName = page.locator('#message-list button[data-profile-user-id]', { hasText: /\w/ }).last()
  await authorName.hover()
  await expect(card).toBeVisible()
  await expect(card.locator('#profile-card-username')).toHaveText(`@${owner.username}`)
  await expect(card.locator('#profile-card-owner')).toBeVisible()
  await expect(card.locator('#profile-card-bio strong')).toHaveText(marker)

  // The card stays inside the viewport, and sits next to the trigger it opened from.
  const viewport = page.viewportSize()
  const box = await card.boundingBox()
  expect(box.x).toBeGreaterThanOrEqual(0)
  expect(box.y).toBeGreaterThanOrEqual(0)
  expect(box.x + box.width).toBeLessThanOrEqual(viewport.width)
  expect(box.y + box.height).toBeLessThanOrEqual(viewport.height)
  const trigger = await authorName.boundingBox()
  expect(Math.abs(box.x - trigger.x)).toBeLessThan(box.width)

  // Esc closes it.
  await page.keyboard.press('Escape')
  await expect(card).toHaveCount(0)

  // An @mention in text opens the same card.
  await row.locator('[data-profile-username]').hover()
  await expect(card).toBeVisible()
  await expect(card.locator('#profile-card-name')).toBeVisible()

  // Moving the pointer away closes it.
  await page.mouse.move(5, 5)
  await expect(card).toHaveCount(0)

  // A member row in the sidebar opens it on click.
  await page.locator(`#member-presence-list [data-profile-user-id], aside [data-profile-user-id]`).first().click()
  await expect(card).toBeVisible()
  await page.screenshot({ path: testInfo.outputPath('profile-card.png') })
})
