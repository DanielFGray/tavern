const { test, expect } = require('@playwright/test')

const { command, login } = require('./support')

// The handles exist only where the panels dock, at desktop widths.
test.skip(({ isMobile }) => isMobile, 'side panels are drawers on a phone')

const width = (locator) => locator.evaluate((el) => Math.round(el.getBoundingClientRect().width))

/** Drag a handle horizontally by `dx` pixels with the mouse. */
async function drag(page, handle, dx) {
  const box = await handle.boundingBox()
  const x = box.x + box.width / 2
  const y = box.y + box.height / 2
  await page.mouse.move(x, y)
  await page.mouse.down()
  await page.mouse.move(x + dx / 2, y)
  await page.mouse.move(x + dx, y)
  await page.mouse.up()
}

test('dragging the channel list edge resizes it, survives patches and reloads, and resets', async ({ page }) => {
  await login(page)
  const drawer = page.locator('#mobile-channel-drawer')
  const handle = page.locator('#mobile-channel-drawer-resize')

  expect(await width(drawer)).toBe(256)
  await drag(page, handle, 40)
  expect(await width(drawer)).toBe(296)
  await expect(handle).toHaveAttribute('aria-valuenow', '296')

  // Past the bound the width stops at the panel's max-width: 25vw of a 1280px window.
  await drag(page, handle, 200)
  expect(await width(drawer)).toBe(320)
  await expect(handle).toHaveAttribute('aria-valuemax', '320')

  // A LiveView patch re-renders the shell; the width and the hook's attributes stay.
  await page.locator('#toggle-members-sidebar').click()
  await expect(page.locator('#toggle-members-sidebar')).toHaveAttribute('aria-pressed', 'false')
  expect(await width(drawer)).toBe(320)
  await expect(handle).toHaveAttribute('aria-valuenow', '320')

  // The root layout applies the saved width before the LiveView connects.
  await page.reload({ waitUntil: 'domcontentloaded' })
  expect(await width(drawer)).toBe(320)

  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
  await handle.dblclick()
  expect(await width(drawer)).toBe(256)
  expect(await page.evaluate(() => localStorage.getItem('tavern:panel-width:channels'))).toBeNull()
})

test('arrow keys, Home and End move the member list separator', async ({ page }) => {
  await login(page)
  const drawer = page.locator('#mobile-members-drawer')
  const handle = page.locator('#mobile-members-drawer-resize')

  expect(await width(drawer)).toBe(240)
  await handle.focus()
  // The handle sits on the panel's left edge, so moving it left widens the panel.
  await page.keyboard.press('ArrowLeft')
  await page.keyboard.press('ArrowLeft')
  expect(await width(drawer)).toBe(272)
  await page.keyboard.press('ArrowRight')
  expect(await width(drawer)).toBe(256)
  await page.keyboard.press('Home')
  expect(await width(drawer)).toBe(192)
  await page.keyboard.press('End')
  expect(await width(drawer)).toBe(282)
  await expect(handle).toHaveAttribute('aria-valuenow', '282')
})

test('the voice channel chat keeps its width across channel switches', async ({ page, request }) => {
  await command(request, 'ensure_channel', { slug: 'e2e-voice-resize', name: 'voice-resize', kind: 'voice' })
  await login(page, { next: '/?channel=e2e-voice-resize' })
  const chat = page.locator('#voice-chat')

  expect(await width(chat)).toBe(384)
  await drag(page, page.locator('#voice-chat-resize'), -100)
  expect(await width(chat)).toBe(484)

  await page.locator('#channel-link-general').click()
  await expect(chat).toHaveCount(0)
  await page.locator('#channel-link-e2e-voice-resize').click()
  await expect(chat).toBeVisible()
  expect(await width(chat)).toBe(484)
})
