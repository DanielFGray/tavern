const { test, expect } = require('@playwright/test')

const baseURL = 'http://127.0.0.1:4001'
const owner = { email: 'e2e@example.com', username: 'e2e_user', password: 'supersecurepass' }

async function login(page, next) {
  const url = new URL('/api/testing/command', baseURL)
  url.searchParams.set('command', 'login')
  url.searchParams.set('payload', JSON.stringify({ ...owner, next }))
  await page.goto(url.toString())
  await expect(page.locator('#server-shell[data-hydrated="true"]')).toBeVisible({ timeout: 60_000 })
}

// Each code block in a rendered message is wrapped by .message-code-block; the code element is inside it.
const blockCode = (scope, index) => scope.locator('.message-code-block code').nth(index)

test('a tagged fenced block is highlighted and an untagged one stays plain', async ({ page, request }) => {
  const stamp = Date.now()
  const slug = `code-highlight-${stamp}`
  const title = `Highlight ${stamp}`
  const response = await request.post(new URL('/api/testing/command', baseURL).toString(), {
    data: { command: 'ensure_channel', slug, name: 'Highlight', kind: 'forum' },
  })
  expect(response.ok()).toBeTruthy()
  await login(page, `/?channel=${slug}`)
  await expect(page.locator('#forum-tab')).toBeVisible()

  // The post body is raw markdown, so each fence goes in exactly as an author would type it.
  const body = [
    `Intro ${stamp}`,
    '',
    '```js',
    'const total = 42 // answer',
    '```',
    '',
    '```py',
    'def greet(name): return name',
    '```',
    '',
    '```',
    'total = 42 # no language tag',
    '```',
  ].join('\n')

  await page.locator('#new-forum-post').click()
  await page.locator('#forum-post-form input[name="post[title]"]').fill(title)
  await page.locator('#forum-post-form textarea[name="post[body]"]').fill(body)
  await page.locator('#submit-forum-post').click()

  const thread = page.locator('[id^="thread-message-list-"]')
  const message = thread.locator(`[data-markdown-source*="${stamp}"]`)
  await expect(message.locator('.message-code-block')).toHaveCount(3)

  const tagged = blockCode(message, 0)
  await expect(tagged.locator('.hljs-keyword', { hasText: 'const' })).toHaveCount(1)
  await expect(tagged.locator('.hljs-number', { hasText: '42' })).toHaveCount(1)
  await expect(tagged.locator('.hljs-comment')).toHaveCount(1)

  await expect(blockCode(message, 1).locator('.hljs-keyword', { hasText: 'def' })).toHaveCount(1)

  const untagged = blockCode(message, 2)
  await expect(untagged).toContainText('total = 42 # no language tag')
  await expect(untagged.locator('[class*="hljs-"]')).toHaveCount(0)
})
