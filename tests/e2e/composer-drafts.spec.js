const { test, expect } = require('@playwright/test')

const { login, unique: runSuffix } = require('./support')

// Unsent composer text is kept per conversation in localStorage (assets/js/composer_drafts.js),
// and a deploy reloads open tabs (TavernWeb.ReloadOnNewBuild), so a draft must outlive both.

const composer = page => page.locator('#message-form [contenteditable="true"]').first()

async function openChannel(page, slug) {
  await page.locator(`#channel-link-${slug}`).click()
  await expect(page).toHaveURL(new RegExp(`\\?channel=${slug}$`))
}

async function reload(page) {
  await page.reload()
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)
}

test.beforeEach(async ({ isMobile }) => {
  test.skip(isMobile, 'channel links sit in the mobile drawer; the draft logic is the same')
})

test('a draft survives a reload and waits in its own channel', async ({ page }, testInfo) => {
  const draft = `unsent ${runSuffix(testInfo)}`
  await login(page)
  await openChannel(page, 'engineering')

  await composer(page).click()
  await composer(page).pressSequentially(draft)

  await reload(page)
  await expect(composer(page)).toHaveText(draft)

  await openChannel(page, 'random')
  await expect(composer(page)).toHaveText('')

  await openChannel(page, 'engineering')
  await expect(composer(page)).toHaveText(draft)

  await composer(page).press('Enter')
  await expect(page.locator(`#message-list [data-markdown-source="${draft}"]`)).toHaveCount(1)
  await expect(composer(page)).toHaveText('')

  await reload(page)
  await expect(composer(page)).toHaveText('')
})

test('a draft the editor cannot read is dropped, not restored', async ({ page }) => {
  await login(page)
  await openChannel(page, 'random')
  const key = await page.locator('#message-form').getAttribute('data-draft-key')

  await page.evaluate(key => {
    localStorage.setItem(`tavern:draft:${key}`, JSON.stringify({type: 'doc', content: [{type: 'noSuchNode'}]}))
  }, key)
  await reload(page)

  await expect(composer(page)).toHaveText('')
  expect(await page.evaluate(key => localStorage.getItem(`tavern:draft:${key}`), key)).toBeNull()

  await composer(page).click()
  await composer(page).pressSequentially('still works')
  await expect(composer(page)).toHaveText('still works')
})

test('a new build reloads the tab at most once a minute', async ({ page }) => {
  await page.clock.install()
  await login(page)

  const staticChanged = () => page.evaluate(() => window.dispatchEvent(new Event('phx:static_changed')))

  let loaded = page.waitForEvent('load')
  await staticChanged()
  await loaded
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/)

  // A second report within the minute, as when the reloaded page meets the other server.
  await page.evaluate(() => { window.__second = true })
  await staticChanged()
  await page.clock.runFor(1_000)
  expect(await page.evaluate(() => window.__second)).toBe(true)

  loaded = page.waitForEvent('load')
  await page.clock.fastForward(60_000)
  await loaded
  expect(await page.evaluate(() => window.__second)).toBeUndefined()
})
