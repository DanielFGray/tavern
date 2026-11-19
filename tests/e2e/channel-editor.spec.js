const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'
const owner = { email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass' }

async function login(page) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ ...owner, next: '/' }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
}

// Drags by the handle in steps, so the hook sees moves between down and up. On a phone in
// Chromium it sends real touch events through CDP; elsewhere the mouse makes pointer events.
async function drag(page, handle, target, { touch }) {
  const from = await handle.boundingBox()
  const to = await target.boundingBox()
  const start = { x: from.x + from.width / 2, y: from.y + from.height / 2 }
  const end = { x: to.x + to.width / 2, y: to.y + to.height / 2 }
  const steps = 8
  const at = (i) => ({
    x: start.x + ((end.x - start.x) * i) / steps,
    y: start.y + ((end.y - start.y) * i) / steps,
  })

  if (touch) {
    const cdp = await page.context().newCDPSession(page)
    const send = (type, p) =>
      cdp.send('Input.dispatchTouchEvent', { type, touchPoints: p ? [{ ...p, id: 1 }] : [] })
    await send('touchStart', start)
    for (let i = 1; i <= steps; i++) await send('touchMove', at(i))
    await send('touchEnd')
  } else {
    await page.mouse.move(start.x, start.y)
    await page.mouse.down()
    for (let i = 1; i <= steps; i++) await page.mouse.move(at(i).x, at(i).y)
    await page.mouse.up()
  }
}

test('an owner edits the channel list in place', async ({ page, browserName, isMobile }, testInfo) => {
  const tag = `${testInfo.project.name}-${Date.now()}`.replace(/[^a-z0-9]+/gi, '-').toLowerCase()
  const shot = (name) => page.screenshot({ path: testInfo.outputPath(`${name}.png`) })

  await login(page)
  if (isMobile) {
    await page.locator('#open-mobile-sidebar').click()
    await expect(page.locator('#mobile-channel-drawer')).toBeInViewport()
  }

  await page.locator('#toggle-channel-edit').click()
  await expect(page.locator('#channel-edit-list')).toBeVisible()

  // A category, then a forum channel at the top level.
  await page.locator('#add-category').click()
  await page.locator('#new-category-form input[type=text]').fill(`Box ${tag}`)
  await page.locator('#create-category').click()
  const categoryRow = page.locator(`input[data-original="Box ${tag}"]`)
  await expect(categoryRow).toBeVisible()
  const categoryId = await categoryRow.getAttribute('data-id')

  await page.locator('#add-channel-top').click()
  await page.locator('#new-channel-form input[type=text]').fill(`Post ${tag}`)
  await page.locator('#new-channel-form select').selectOption('forum')
  await page.locator('#create-channel').click()
  const nameField = page.locator(`input[data-original="Post ${tag}"]`)
  await expect(nameField).toBeVisible()
  const channelId = await nameField.getAttribute('data-id')

  // Inline rename on Enter.
  await nameField.fill(`Ideas ${tag}`)
  await nameField.press('Enter')
  await expect(page.locator(`#rename-channel-${channelId}`)).toHaveAttribute(
    'data-original',
    `Ideas ${tag}`
  )
  await shot('1-edit-mode')

  // Drag the channel into the new category.
  const dropList = page.locator(`#edit-section-${categoryId} [data-drop-list="channels"]`)
  await drag(page, page.locator(`#drag-channel-${channelId}`), dropList, {
    touch: isMobile && browserName === 'chromium',
  })
  await expect(page.locator(`#edit-section-${categoryId} #edit-channel-${channelId}`)).toBeVisible()
  await shot('2-after-drag')

  // The ⚙ popover beside the row (a bottom sheet on a phone).
  await page.locator(`#channel-settings-${channelId}`).click()
  const popover = page.locator('#channel-settings-popover')
  await expect(popover).toBeVisible()
  await expect(popover).toBeInViewport({ ratio: 1 })
  await popover.locator('textarea').fill('Where ideas go')
  await page.locator('#channel-settings-save').click()
  await expect(popover.locator('textarea')).toHaveValue('Where ideas go')
  await shot('3-popover')
  await page.keyboard.press('Escape')
  await expect(popover).toHaveCount(0)

  // Delete at once, then restore.
  await page.locator(`#delete-channel-${channelId}`).click()
  await expect(page.locator(`#deleted-channel-${channelId}`)).toBeVisible()
  await shot('4-deleted')
  await page.locator(`#restore-channel-${channelId}`).click()
  await expect(page.locator(`#edit-channel-${channelId}`)).toBeVisible()

  // No horizontal overflow at this width.
  const overflow = await page.evaluate(
    () => document.documentElement.scrollWidth - document.documentElement.clientWidth
  )
  expect(overflow).toBeLessThanOrEqual(0)

  // Leave the seeded list as it was: both rows go to Recently deleted.
  await page.locator(`#delete-channel-${channelId}`).click()
  await page.locator(`#delete-channel-${categoryId}`).click()
  await expect(page.locator(`#deleted-channel-${categoryId}`)).toBeVisible()

  await page.locator('#toggle-channel-edit').click()
  await expect(page.locator('#channel-edit-list')).toHaveCount(0)
  await shot('5-done')
})
