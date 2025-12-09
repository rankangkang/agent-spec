---
description: React 编码规范
globs: *.ts, *.tsx, *.jsx, *.js
priority: 10
---

# React 编码规范

## 组件示例

```ts
// path: Component.tsx
export interface ComponentProps {
  // ... props
}

export const Component = (props: ComponentProps) => {
  const {  } = props
  return (
    <div></div>
  )
}
```

## hook 示例

```ts
// path: useHook.tsx
export const useHook = () => {
  // logic here
}
```
