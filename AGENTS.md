# familyapp 开发规范

## 开发原则

- 修改前先理解现有架构、调用链和数据流；先搜索，再分析影响范围，最后修改。
- 优先修复根因，不用表面补丁掩盖设计问题。
- 最大复用已有实现、最小新增；已有能力应扩展而非复制。
- 不做无关大重构，不为小需求引入复杂架构，也不删除已验证可用的能力。

## 架构复用

新增或修改前优先检查已有的 Model/Entity、Repository、Service、API/Router、Settings、Auth/Device/Session、Recovery、Sync、Location 与 UI Components。

禁止创建重复 Model、Service、认证体系、同步体系或状态管理。新增模块必须在实现说明中写明：现有实现为何不能满足，以及新增部分如何兼容既有架构。

## 数据与安全

- 保持单一事实源；不要随意添加重复字段或改变已有 UUID、身份标识与数据语义。
- 新功能须考虑创建、更新、删除、恢复、权限、同步与迁移路径。
- 权限必须在 Repository、业务层或后端校验；仅隐藏 UI 不构成安全控制。
- 禁止输出、记录或提交密码、Token、Secret、Recovery 信息及其他凭证。

## iOS 规范

- 保持 SwiftUI 原生、简洁、低饱和的既有风格；视觉调整不得改变业务逻辑。
- 优先复用现有组件，维持 SwiftData 与 Repository 的边界清晰。
- 遵守 Swift 6 并发与 actor isolation；不要以 `@unchecked Sendable` 或 `nonisolated(unsafe)` 绕过安全检查，除非有明确、审查过的必要性。

## Backend 与同步

- 后端保持 FastAPI、SQLAlchemy、Alembic、PostgreSQL；不修改历史 migration，数据库变更新增 migration，并处理事务、幂等与回滚。
- 默认运行模式始终是 `AppRuntimeMode.localOnly`。新增功能不得自动启动远端同步、联网或改变本地运行模式；远端能力必须与本地逻辑隔离。

## 成员与交付

- 身份使用稳定 UUID；`displayName` 仅作展示，不能作为主键。
- 完成后说明修改文件、原因、影响模块、是否需要数据迁移、验证范围与剩余风险。
