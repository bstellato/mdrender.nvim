# Operator splitting for quadratic programs

A short note on **first-order methods** for problems with variable $x \in \mathbf{R}^n$,
written in plain Markdown. See the [OSQP paper](https://osqp.org) for details.

## Problem

Given $P \in \mathbf{S}^n_+$, $q$, $A$, and bounds $l \le u$, we solve

$$
\begin{array}{ll}
\text{minimize}   & (1/2) x^T P x + q^T x \\
\text{subject to} & l \le A x \le u
\end{array}
$$

with optimal value $p^\star$. Each iteration costs one solve with a *fixed* matrix.

- Factor the KKT matrix once
  - reuse it while $\rho$ is unchanged
- [x] Warm start from the previous solution
- [ ] Polish the final iterate

> Convergence is linear when the objective is strongly convex.

```python
import cvxpy as cp

x = cp.Variable(n)
cost = 0.5 * cp.quad_form(x, P) + q @ x  # objective
cp.Problem(cp.Minimize(cost), [l <= A @ x, A @ x <= u]).solve(solver="OSQP")
```

| Solver   | Method         | Time (s) | Accuracy              |
|:---------|:---------------|---------:|:---------------------:|
| OSQP     | ADMM           |     0.12 | $\epsilon = 10^{-4}$  |
| Clarabel | interior point |     0.30 | $\epsilon = 10^{-8}$  |

Timings are for a single core.
