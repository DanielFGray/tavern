const { test, expect } = require('@playwright/test')

const { command, login, openSidebar, unique } = require('./support')

// Sets the tab's visibility the way the browser does when the member switches tabs.
async function setVisibility(page, state) {
  await page.evaluate((state) => {
    Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => state })
    document.dispatchEvent(new Event('visibilitychange'))
  }, state)
}

async function switchChannel(page, slug) {
  await openSidebar(page)
  await page.locator(`#channel-link-${slug}`).click()
  await expect(page).toHaveURL(new RegExp(`\\?channel=${slug}$`))
}

test('a message that arrives in a hidden tab stays unread until the tab is seen', async ({ page, request }, testInfo) => {
  const suffix = unique(testInfo)
  const { user: sender } = await command(request, 'upsert_user', {
    email: `test_unseen_${suffix}@example.com`,
    username: `test_unseen_${suffix}`,
  })
  const post = async (body) => {
    const { message } = await command(request, 'create_message', { channel_slug: 'general', username: sender.username, body })
    await expect(page.locator(`#messages-${message.id}`)).toBeAttached()
  }

  await login(page, { next: '/?channel=general' })

  // Seen again before leaving: read.
  await setVisibility(page, 'hidden')
  await post(`seen later ${suffix}`)
  await setVisibility(page, 'visible')
  await switchChannel(page, 'engineering')
  await expect(page.locator('#channel-link-engineering')).toBeVisible()
  await expect(page.locator('#channel-unread-general')).toHaveCount(0)

  // Left while still hidden: unread.
  await switchChannel(page, 'general')
  await setVisibility(page, 'hidden')
  await post(`never seen ${suffix}`)
  await switchChannel(page, 'engineering')
  await expect(page.locator('#channel-unread-general')).toHaveText('1')
})
