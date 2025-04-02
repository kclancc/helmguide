from flask import Flask
import os

def create_app():
    app = Flask(__name__, 
                template_folder='../templates',  # Points to templates directory one level up
                static_folder='../static')       # Points to static directory one level up
    
    from app.routes import bp
    app.register_blueprint(bp)
    
    return app
