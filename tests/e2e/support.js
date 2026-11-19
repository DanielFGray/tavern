const { expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

// The seed owner that priv/repo/e2e_reset.exs registers before every run.
const owner = { email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass' }

/** Run a test-support server command and return its JSON data. */
async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

/**
 * Log in through the test-support endpoint, which sets the session cookie and redirects to
 * `next`, then wait until the LiveView has connected and loaded the shell. A control clicked
 * before that is lost to the connecting mount.
 */
async function login(page, { next = '/', ...account } = {}) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ ...owner, ...account, next }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
  await expect(page.locator('[data-phx-main]')).toHaveClass(/phx-connected/, { timeout: 60_000 })
}

/**
 * On a phone the channel list, user menu and theme buttons live in a drawer that is
 * translated off-screen until opened; on a desktop the sidebar is always there.
 */
async function openSidebar(page) {
  const opener = page.locator('#open-mobile-sidebar')
  const drawer = page.locator('#mobile-channel-drawer')
  const isOpen = () => drawer.evaluate((el) => el.classList.contains('translate-x-0'))
  if ((await opener.isVisible()) && !(await isOpen())) {
    await opener.click()
    await expect(drawer).toHaveClass(/translate-x-0/)
    await expect(drawer).toBeInViewport({ ratio: 1 })
  }
}

async function openUserMenu(page) {
  await openSidebar(page)
  await page.locator('#user-menu-button').click()
  await expect(page.locator('#user-menu')).toBeVisible()
}

/**
 * A suffix that differs per run and per project, so names a spec creates never collide with an
 * earlier run's. It is 9 lowercase letters and digits, so it also fits a username (24 characters).
 */
function unique(testInfo) {
  return `${testInfo.project.name[0]}${Date.now().toString(36)}`
}

module.exports = { baseURL, owner, command, login, openSidebar, openUserMenu, unique }
