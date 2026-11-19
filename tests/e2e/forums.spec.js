const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'

async function command(request, name, payload = {}) {
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: name, ...payload },
  })
  expect(response.ok()).toBeTruthy()
  return (await response.json()).data
}

async function login(page, next) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass', next }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible()
}

test('a member posts in a forum and filters the posts by a tag', async ({ page, request }) => {
  await command(request, 'ensure_channel', { slug: 'e2e-forum', name: 'Forum', kind: 'forum' })
  await login(page, '/?channel=e2e-forum')

  const stamp = Date.now()
  const tag = `tag${stamp}`
  const tagged = `Tagged ${stamp}`
  const plain = `Plain ${stamp}`

  for (const [title, body] of [[plain, 'no tags here'], [tagged, `about #${tag}`]]) {
    await page.locator('#new-forum-post').click()
    await page.locator('#forum-post-form input[name="post[title]"]').fill(title)
    await page.locator('#forum-post-form textarea[name="post[body]"]').fill(body)
    await page.locator('#submit-forum-post').click()

    // Posting opens the new post's thread, with its first message inside.
    await expect(page.locator('[id^="thread-message-list-"]', { hasText: body })).toBeVisible()
    await page.locator('[id^="thread-back-to-channel-"]').click()
    await expect(page.locator('#forum-posts')).toBeVisible()
  }

  const posts = page.locator('#forum-posts > li')
  await expect(posts.filter({ hasText: plain })).toHaveCount(1)
  await expect(posts.filter({ hasText: tagged })).toHaveCount(1)

  await posts.filter({ hasText: tagged }).locator(`[id$="-${tag}"]`).click()

  await expect(page.locator('#forum-search input')).toHaveValue(`#${tag}`)
  await expect(posts).toHaveCount(1)
  await expect(posts.first()).toContainText(tagged)
})
