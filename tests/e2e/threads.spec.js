const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function login(page) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass', next: '/?channel=general' }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
}

test('a member follows a thread and sees it in the sidebar', async ({ page, request }) => {
  await login(page)
  const unique = `Follow me ${Date.now()}`
  const { message } = await command(request, 'create_message', {
    channel_slug: 'general',
    username: 'e2e_user',
    body: unique,
  })

  // The message arrives over the socket. A tap on its body opens its action bar, on touch screens too.
  const starter = page.locator(`#message-list [data-markdown-source="${unique}"]`)
  await expect(starter).toBeVisible()
  await starter.click()
  await page.locator(`#create-thread-${message.id}`).click()

  const followButton = page.locator(`#toggle-follow-thread-${message.id}`)
  await expect(followButton).toHaveAttribute('aria-pressed', 'true')

  // Creating the thread followed it, so it shows under #general.
  const sidebarThread = page.locator('#sidebar-threads-general a', { hasText: unique })
  await expect(sidebarThread).toBeVisible()

  await followButton.click()
  await expect(followButton).toHaveAttribute('aria-pressed', 'false')
  await expect(sidebarThread).toHaveCount(0)

  await followButton.click()
  await expect(followButton).toHaveAttribute('aria-pressed', 'true')
  await expect(sidebarThread).toBeVisible()
})
