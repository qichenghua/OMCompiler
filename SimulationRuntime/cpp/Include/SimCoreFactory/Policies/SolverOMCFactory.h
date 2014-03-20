#pragma once

#include <ObjectFactory.h>
#include <Solver/ISolver.h>
#include <SimulationSettings/ISettingsFactory.h>

/*
Policy class to create solver object
*/
template <class CreationPolicy> 
struct SolverOMCFactory : public  ObjectFactory<CreationPolicy>
{

public:
    SolverOMCFactory(PATH library_path,PATH modelicasystem_path,PATH config_path)
        :ObjectFactory<CreationPolicy>(library_path,modelicasystem_path,config_path)
    {
         _solver_type_map = new type_map();
         _settings_type_map = new type_map();
#ifndef ANALYZATION_MODE
         initializeLibraries(library_path,modelicasystem_path,config_path);
#endif
    }

    virtual ~SolverOMCFactory()
    {
      delete _solver_type_map;
      delete _settings_type_map;
        ObjectFactory<CreationPolicy>::_factory->UnloadAllLibs();
    }

    virtual boost::shared_ptr<ISettingsFactory> createSettingsFactory()
    {
          std::map<std::string, factory<ISettingsFactory,PATH,PATH,PATH> >::iterator iter;
          std::map<std::string, factory<ISettingsFactory,PATH,PATH,PATH> >& factories(_settings_type_map->get());
          iter = factories.find("SettingsFactory");
          if (iter ==factories.end())
          {
                throw std::invalid_argument("No such settings library");
            }
         boost::shared_ptr<ISettingsFactory>  settings_factory = boost::shared_ptr<ISettingsFactory>(iter->second.create(ObjectFactory<CreationPolicy>::_library_path,ObjectFactory<CreationPolicy>::_modelicasystem_path,ObjectFactory<CreationPolicy>::_config_path));

         return settings_factory;
    }

    virtual boost::shared_ptr<ISolver> createSolver(IMixedSystem* system, string solvername, boost::shared_ptr<ISolverSettings> solver_settings)
    {
        
        if(solvername.compare("euler")==0)
        {
             PATH euler_path = ObjectFactory<CreationPolicy>::_library_path;
            PATH euler_name(EULER_LIB);
            euler_path/=euler_name;
            LOADERRESULT result = ObjectFactory<CreationPolicy>::_factory->LoadLibrary(euler_path.string(),*_solver_type_map);
            if (result != LOADER_SUCCESS)
            {
                throw std::runtime_error("Failed loading Euler solver library!");
            }
            
        }
        else if(solvername.compare("idas")==0)
        {
           
        }
        else if(solvername.compare("ida")==0)
        {
        }
        else if((solvername.compare("cvode")==0)||(solvername.compare("dassl")==0))
        {
            solvername = "cvode"; //workound for dassl, using cvode instead
      PATH cvode_path = ObjectFactory<CreationPolicy>::_library_path;
            PATH cvode_name(CVODE_LIB);
            cvode_path/=cvode_name;
            LOADERRESULT result = ObjectFactory<CreationPolicy>::_factory->LoadLibrary(cvode_path.string(),*_solver_type_map);
            if (result != LOADER_SUCCESS)
            {
                throw std::runtime_error("Failed loading CVode solver library!");
            }
        }
        else
            throw std::invalid_argument("Selected Solver is not available");
        
        std::map<std::string, factory<ISolver,IMixedSystem*, ISolverSettings*> >::iterator iter;
        std::map<std::string, factory<ISolver,IMixedSystem*, ISolverSettings*> >& factories(_solver_type_map->get());
        string solver_key = solvername.append("Solver");
       iter = factories.find(solver_key);
        if (iter ==factories.end())
        {
                throw std::invalid_argument("No such Solver " + solver_key);
        }
        
        boost::shared_ptr<ISolver> solver = boost::shared_ptr<ISolver>(iter->second.create(system,solver_settings.get()));
       
        return solver;
    }
protected:
    virtual void initializeLibraries(PATH library_path,PATH modelicasystem_path,PATH config_path)
    {
        PATH settingsfactory_path = ObjectFactory<CreationPolicy>::_library_path;
        PATH settingsfactory_name(SETTINGSFACTORY_LIB);
        settingsfactory_path/=settingsfactory_name;

        LOADERRESULT result = ObjectFactory<CreationPolicy>::_factory->LoadLibrary(settingsfactory_path.string(),*_settings_type_map);

        if (result != LOADER_SUCCESS)
        {

            throw std::runtime_error("Failed loading SimulationSettings library!");
        }

        PATH solver_path = ObjectFactory<CreationPolicy>::_library_path;
        PATH solver_name(SOLVER_LIB);
        solver_path/=solver_name;

        result = ObjectFactory<CreationPolicy>::_factory->LoadLibrary(solver_path.string(),*_solver_type_map);

        if (result != LOADER_SUCCESS)
        {
            throw std::runtime_error("Failed loading Solver default implementation library!");
        }
    }

    type_map* _solver_type_map;
    type_map* _settings_type_map;
};
