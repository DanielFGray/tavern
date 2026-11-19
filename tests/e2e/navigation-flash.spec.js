const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'
const owner = { email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass' }

async function openApp(page, request, slugs) {
  for (const slug of slugs) {
    const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
      data: { command: 'ensure_channel', slug, name: slug, kind: 'text' },
    })
    expect(response.ok()).toBeTruthy()
  }
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ ...owner, next: `/?channel=${slugs[0]}` }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
}

// Records every moment a loading placeholder (a pulsing skeleton or "Loading" text) is in the
// DOM, including one that lives for a single frame.
async function watchForLoadingState(page) {
  await page.evaluate(() => {
    window.__loadingSeen = []
    const check = () => {
      const section = document.querySelector('#server-shell section')
      if (!section) return
      if (section.querySelector('.animate-pulse') || /Loading/.test(section.textContent)) {
        window.__loadingSeen.push(performance.now())
      }
    }
    new MutationObserver(check).observe(document.body, { subtree: true, childList: true, characterData: true })
  })
}

async function openSidebarIfNeeded(page) {
  const toggle = page.locator('#open-mobile-sidebar')
  if (await toggle.isVisible().catch(() => false)) await toggle.click()
}

test('switching channels never shows a loading state', async ({ page, request }) => {
  const stamp = Date.now()
  const a = `flash-a-${stamp}`
  const b = `flash-b-${stamp}`
  const c = `flash-c-${stamp}`
  await openApp(page, request, [a, b, c])
  await watchForLoadingState(page)

  const timings = []
  for (const slug of [b, c, a]) {
    await openSidebarIfNeeded(page)
    const started = Date.now()
    await page.locator(`#channel-link-${slug}`).click()
    await expect(page).toHaveURL(new RegExp(`channel=${slug}$`))
    await expect(page.locator('#message-scroll-region')).toBeVisible()
    timings.push(Date.now() - started)
  }
  console.log(`channel switch click-to-content ms: ${timings.join(', ')}`)

  expect(await page.evaluate(() => window.__loadingSeen)).toEqual([])
})

test('rapid clicks across three channels end on the last one clicked', async ({ page, request }) => {
  const stamp = Date.now()
  const a = `rapid-a-${stamp}`
  const b = `rapid-b-${stamp}`
  const c = `rapid-c-${stamp}`
  await openApp(page, request, [a, b, c])
  await watchForLoadingState(page)

  // Without waiting between clicks, in the desktop layout where all links are visible.
  test.skip(await page.locator('#open-mobile-sidebar').isVisible(), 'the drawer hides the links on a phone')
  const first = page.locator(`#channel-link-${b}`)
  await first.click({ noWaitAfter: true })
  await page.locator(`#channel-link-${c}`).click({ noWaitAfter: true })
  await page.locator(`#channel-link-${a}`).click({ noWaitAfter: true })

  await expect(page).toHaveURL(new RegExp(`channel=${a}$`))
  await expect(page.locator('#message-scroll-region')).toBeVisible()
  await expect(page.locator('#channel-message-count').first()).toBeAttached()
  expect(await page.evaluate(() => window.__loadingSeen)).toEqual([])
})
