const { test, expect } = require('@playwright/test')

const { command, login, unique } = require('./support')

// A channel opens on its newest 50 messages. Scrolling up to "Load older messages" loads the page
// before them (MessageListHook), and the message the reader was looking at stays in place.

test('scrolling up loads older messages without moving the view', async ({ page, request }, testInfo) => {
  const slug = `history-${unique(testInfo)}`
  await command(request, 'ensure_channel', { slug, name: slug })
  await command(request, 'fill_channel', { slug, count: 70, prefix: slug })

  await login(page, { next: `/?channel=${slug}` })
  const region = page.locator('#message-scroll-region')
  const row = n => page.locator(`#message-list [data-markdown-source="${slug} ${n}"]`)

  await expect(row(70)).toBeInViewport()
  await expect(row(21)).toHaveCount(1)
  await expect(row(20)).toHaveCount(0)

  // The newest page alone shows the button; a view that has not scrolled up does not press it.
  await expect(page.locator('#load-older-channel')).toHaveCount(1)
  await expect(row(20)).toHaveCount(0)

  const top = () => row(21).evaluate(el => el.getBoundingClientRect().top)
  await region.evaluate(el => { el.scrollTop = 0 })
  await expect(row(1)).toHaveCount(1)
  await expect(page.locator('#load-older-channel')).toHaveCount(0)
  const order = await page.locator('#message-list [data-markdown-source]').evaluateAll(nodes =>
    nodes.map(node => node.dataset.markdownSource))
  expect(order).toEqual(Array.from({ length: 70 }, (_, i) => `${slug} ${i + 1}`))

  // Row 21 was at the top of the view before the older page arrived, and is still near it.
  const regionTop = await region.evaluate(el => el.getBoundingClientRect().top)
  expect(Math.abs((await top()) - regionTop)).toBeLessThan(120)
})
