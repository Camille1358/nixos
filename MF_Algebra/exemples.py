# Exemples MF Algebra (d'après workspace/demo.py du projet). Rendre une scène : mfa exemples.py Resoudre
# Documentation : https://github.com/TheMathematicFanatic/MF_Algebra (et le PDF MF_Algebra_Docs_by_Ed)
from manim import *
from MF_Algebra import *


algebra_config['multiplication_mode'] = 'dot'


class Evaluer(Scene):
    """Remplace x et y par des nombres dans une expression, puis calcule."""
    def construct(self):
        exp = 3*x**2 - (4+x)/sqrt(y-1)
        E = Evaluate(exp, auto_color={x: RED, y: BLUE})
        E >> substitute_({x: 8, y: 10}, maintain_color=True)
        E.play_all(self)


class Resoudre(Scene):
    """Résout une équation pas à pas : 13/(x+8)² + 5 = 10."""
    def construct(self):
        eq = 13/(x+8)**2 + 5 | 10
        T = Solve(x, eq)
        T.play_all(self)
