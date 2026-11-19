const { test, expect } = require('@playwright/test')

const { login, openSidebar, unique } = require('./support')

// Drags by the handle in steps, so the hook sees moves between down and up. On a phone in
// Chromium it sends real touch events through CDP; elsewhere the mouse makes pointer events.
//
// Other specs add channels, so the category and the handle can be further apart than the screen
// is tall. Like a person, the drag then holds the pointer at the edge of the scrolling pane until
// the hook's autoscroll brings the target into view.
async function drag(page, handle, target, { touch }) {
  await handle.scrollIntoViewIfNeeded()
  const viewportHeight = page.viewportSize().height
  const pane = await handle.evaluate((el) => {
    const r = el.closest('.overflow-y-auto').getBoundingClientRect()
    return { top: r.top, bottom: r.bottom }
  })
  const top = Math.max(pane.top, 0) + 8
  const bottom = Math.min(pane.bottom, viewportHeight) - 8
  const center = async (locator) => {
    const b = await locator.boundingBox()
    return { x: b.x + b.width / 2, y: b.y + b.height / 2 }
  }

  let down, move, up
  if (touch) {
    const cdp = await page.context().newCDPSession(page)
    const send = (type, p) =>
      cdp.send('Input.dispatchTouchEvent', { type, touchPoints: p ? [{ ...p, id: 1 }] : [] })
    down = (p) => send('touchStart', p)
    move = (p) => send('touchMove', p)
    up = () => send('touchEnd')
  } else {
    down = async (p) => {
      await page.mouse.move(p.x, p.y)
      await page.mouse.down()
    }
    move = (p) => page.mouse.move(p.x, p.y)
    up = () => page.mouse.up()
  }

  let at = await center(handle)
  await down(at)
  for (let tick = 0; tick < 400; tick++) {
    const to = await center(target)
    if (to.y > top + 48 && to.y < bottom - 48) break
    // The pointer must move for the hook to scroll: a move to the same spot sends no event.
    const jitter = tick % 2
    at = { x: at.x, y: to.y <= top + 48 ? top + jitter : bottom - jitter }
    await move(at)
  }
  // The pane keeps scrolling while the pointer is near its edge, so the target moves under the
  // pointer: aim at where it is now on every step, and once more at the end.
  const steps = 8
  const from = at
  for (let i = 1; i <= steps; i++) {
    const end = await center(target)
    await move({ x: from.x + ((end.x - from.x) * i) / steps, y: from.y + ((end.y - from.y) * i) / steps })
  }
  await move(await center(target))
  await up()
}

test('an owner edits the channel list in place', async ({ page, browserName, isMobile }, testInfo) => {
  const tag = unique(testInfo)
  const shot = (name) => page.screenshot({ path: testInfo.outputPath(`${name}.png`) })

  await login(page)
  await openSidebar(page)

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
