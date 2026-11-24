const { test, expect } = require('@playwright/test')

const { command, login, unique } = require('./support')

// The Search button opens a drawer over the page; a result opens the channel that holds it.

test('searching finds a message and opens its channel', async ({ page, request }, testInfo) => {
  const slug = `search-${unique(testInfo)}`
  const word = `zebra${unique(testInfo).replace(/\W/g, '')}`
  await command(request, 'ensure_channel', { slug, name: slug })
  await command(request, 'fill_channel', { slug, count: 3, prefix: word })

  await login(page, { next: '/?channel=general' })
  await page.locator('#open-message-search').click()
  const field = page.locator('#message-search-form input[type="search"]')
  await expect(field).toBeFocused()
  await field.fill(word.slice(0, -2))

  const rows = page.locator('#message-search-results li')
  await expect(rows).toHaveCount(3)
  await expect(rows.first()).toContainText(`${word} 3`)
  await expect(rows.first()).toContainText(`# ${slug}`)

  await rows.first().locator('button').click()
  await expect(page).toHaveURL(new RegExp(`channel=${slug}`))
  await expect(page.locator('#message-search')).toHaveCount(0)
  await expect(page.locator(`#message-list [data-markdown-source="${word} 3"]`)).toBeVisible()
})
