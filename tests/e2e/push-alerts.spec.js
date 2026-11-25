const { test, expect } = require('@playwright/test')

const { login } = require('./support')

// docs/design/push-notifications.md, "The browser side".

test('the app is installable: manifest, icon and service worker are served', async ({ page, request }) => {
  await login(page)

  const href = await page.locator('link[rel="manifest"]').getAttribute('href')
  const manifest = await (await request.get(href)).json()
  expect(manifest.display).toBe('standalone')

  for (const icon of manifest.icons) {
    expect((await request.get(icon.src)).ok()).toBeTruthy()
  }

  const worker = await request.get('/sw.js')
  expect(worker.ok()).toBeTruthy()
  expect(worker.headers()['content-type']).toContain('javascript')
})

test('the push card shows the state this browser can reach', async ({ page, browserName }) => {
  await login(page)
  await page.goto('/settings?tab=notifications')

  const card = page.locator('#push-alerts')
  await expect(card).not.toHaveAttribute('data-state', 'checking')
  const state = await card.getAttribute('data-state')

  if (browserName === 'webkit') {
    // The iPhone profile: Safari gives push only to a Home Screen app.
    expect(['install', 'unsupported']).toContain(state)
    await expect(card.getByText('add Tavern to the Home Screen')).toBeVisible()
  } else if (state === 'denied') {
    // Headless Chromium refuses notifications even after grantPermissions.
    await expect(card.getByText('blocks notifications')).toBeVisible()
    await expect(page.locator('#enable-push')).toBeHidden()
  } else {
    expect(state).toBe('off')
    await expect(page.locator('#enable-push')).toBeVisible()
  }
})
