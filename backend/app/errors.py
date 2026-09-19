class DomainError(Exception):
    """A safe, user-facing business-rule failure."""


class ForbiddenError(DomainError):
    pass


class ConflictError(DomainError):
    pass


class ValidationError(DomainError):
    pass


class NotFoundError(DomainError):
    pass
