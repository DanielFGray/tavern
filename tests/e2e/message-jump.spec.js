const { test, expect } = require('@playwright/test')

const { command, login, unique } = require('./support')

// A URL's `message` param opens that message in place (TavernWeb.ServerLive.MessageJump): the
// channel loads the window around it and MessageListHook scrolls it into the middle of the view.

test('a message link opens an old message in place, and Jump to present returns', async ({ page, request }, testInfo) => {
  const slug = `jump-${unique(testInfo)}`
  await command(request, 'ensure_channel', { slug, name: slug })
  await command(request, 'fill_channel', { slug, count: 150, prefix: slug })

  const region = page.locator('#message-scroll-region')
  const row = n => page.locator(`#message-list [data-markdown-source="${slug} ${n}"]`)
  const rowId = n => row(n).evaluate(el => el.closest('[id^="messages-"]').id.replace('messages-', ''))

  // Reach message 40 by scrolling up, to learn its id.
  await login(page, { next: `/?channel=${slug}` })
  await expect(row(150)).toBeInViewport()
  while (await row(40).count() === 0) {
    await region.evaluate(el => { el.scrollTop = 0 })
    await page.waitForTimeout(150)
  }
  const id = await rowId(40)

  // A cold load of the link: the window around message 40, scrolled to it, not to the bottom.
  await page.goto(`/?channel=${slug}&message=${id}`)
  await expect(row(40)).toBeInViewport()
  await expect(row(150)).toHaveCount(0)
  await expect(page.locator('#newer-messages-channel')).toHaveCount(1)
  const target = row(40).locator('xpath=ancestor::*[starts-with(@id, "messages-")][1]')
  expect(await target.evaluate(el => el.getAnimations().length)).toBeGreaterThan(0)

  // Scrolling down to the end of the window loads the next page.
  await region.evaluate(el => { el.scrollTop = el.scrollHeight })
  await expect(row(66)).toHaveCount(1)

  await page.locator('#jump-to-present-channel').click()
  await expect(page).not.toHaveURL(/message=/)
  await expect(row(150)).toBeInViewport()
  await expect(page.locator('#newer-messages-channel')).toHaveCount(0)
})

test('a search result opens its message in place', async ({ page, request }, testInfo) => {
  const slug = `jumpsearch-${unique(testInfo)}`
  const word = `okapi${unique(testInfo).replace(/\W/g, '')}`
  await command(request, 'ensure_channel', { slug, name: slug })
  await command(request, 'fill_channel', { slug, count: 1, prefix: word })
  await command(request, 'fill_channel', { slug, count: 120, prefix: slug })

  await login(page, { next: `/?channel=${slug}` })
  await page.locator('#open-message-search').click()
  await page.locator('#message-search-form input[type="search"]').fill(word)
  await page.locator('#message-search-results li button').first().click()

  await expect(page).toHaveURL(/message=/)
  const hit = page.locator(`#message-list [data-markdown-source="${word} 1"]`)
  await expect(hit).toBeInViewport()
  await expect(page.locator(`#message-list [data-markdown-source="${slug} 120"]`)).toHaveCount(0)
})
