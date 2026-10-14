# MINOS-741 DAW bridge (remote script). Copy this folder into the DAW's user library "Remote Scripts" folder and pick
# MINOS741Bridge as a control surface (no input / output ports needed).


def create_instance(c_instance):
    from .bridge import Bridge
    return Bridge(c_instance)
